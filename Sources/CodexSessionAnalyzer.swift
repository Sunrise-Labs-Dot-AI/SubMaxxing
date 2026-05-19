// CodexSessionAnalyzer.swift
// Parse Codex CLI JSONL transcripts for local analytics.

import Foundation

private struct CodexJSONLEntry: Decodable {
    let type: String?
    let timestamp: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let timestamp: String?
    let model: String?
    let cwd: String?
    let info: CodexUsageInfo?
    let usage: CodexTokenUsage?
}

private struct CodexUsageInfo: Decodable {
    let lastTokenUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
    }
}

private struct CodexTokenUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheReadTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }

    var normalized: TokenUsage {
        let rawInput = inputTokens ?? promptTokens ?? 0
        let cached = cachedInputTokens ?? cacheReadTokens ?? 0
        let fullPriceInput = max(rawInput - cached, 0)
        let output = outputTokens ?? completionTokens ?? 0
        return TokenUsage(
            inputTokens: fullPriceInput,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: cached
        )
    }
}

struct CodexSessionSummary {
    let id: String
    let date: Date
    let projectName: String
    let directoryName: String
    let modelUsage: [String: (tokens: TokenUsage, cost: Double, messages: Int)]
    let tokens: TokenUsage
    let cost: Double
    let messages: Int
}

enum CodexSessionAnalyzer {
    static let sessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }()

    private static let jsonDecoder = JSONDecoder()
    private static let maxFileSize: UInt64 = 300 * 1024 * 1024

    static func parseSession(fileURL: URL, since: Date, until: Date = Date()) -> CodexSessionSummary? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        var currentModel: String?
        var currentCwd: String?
        var fallbackDate: Date?
        var modelAgg: [String: (tokens: TokenUsage, cost: Double, messages: Int)] = [:]
        var totalTokens = TokenUsage()
        var totalCost: Double = 0
        var messages = 0
        var firstUsageDate: Date?

        SessionAnalyzer.enumerateJSONLines(in: data) { lineData in
            guard let entry = try? jsonDecoder.decode(CodexJSONLEntry.self, from: lineData) else { return }

            let entryDate = entry.timestamp.flatMap(SessionAnalyzer.parseISO)
                ?? entry.payload?.timestamp.flatMap(SessionAnalyzer.parseISO)

            if fallbackDate == nil {
                fallbackDate = entryDate
            }

            if entry.type == "session_meta" {
                currentCwd = entry.payload?.cwd ?? currentCwd
                return
            }

            if entry.type == "turn_context" {
                currentModel = entry.payload?.model ?? currentModel
                currentCwd = entry.payload?.cwd ?? currentCwd
                return
            }

            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let rawUsage = entry.payload?.info?.lastTokenUsage ?? entry.payload?.usage,
                  let timestamp = entryDate,
                  timestamp >= since,
                  timestamp <= until
            else { return }

            let model = currentModel ?? "gpt-5"
            let tokens = rawUsage.normalized
            guard tokens.totalTokens > 0 else { return }

            let price = ModelPricing.codexPrice(for: model)
            let cost = Double(tokens.inputTokens) * price.input
                + Double(tokens.outputTokens) * price.output
                + Double(tokens.cacheReadTokens) * price.cacheRead

            var modelExisting = modelAgg[model] ?? (tokens: TokenUsage(), cost: 0, messages: 0)
            modelExisting.tokens.add(tokens)
            modelExisting.cost += cost
            modelExisting.messages += 1
            modelAgg[model] = modelExisting

            totalTokens.add(tokens)
            totalCost += cost
            messages += 1
            if firstUsageDate == nil {
                firstUsageDate = timestamp
            }
        }

        guard messages > 0 else { return nil }

        let cwd = currentCwd ?? "Codex"
        return CodexSessionSummary(
            id: fileURL.deletingPathExtension().lastPathComponent,
            date: firstUsageDate ?? fallbackDate ?? fileDate(fileURL) ?? Date(),
            projectName: projectName(from: cwd),
            directoryName: cwd,
            modelUsage: modelAgg,
            tokens: totalTokens,
            cost: totalCost,
            messages: messages
        )
    }

    static func analyze(since: Date, until: Date = Date()) -> UsageStats {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            Log.warn("No Codex sessions directory found at \(sessionsDir.path)")
            return UsageStats()
        }

        let summaries = enumerator.compactMap { item -> CodexSessionSummary? in
            guard let fileURL = item as? URL, fileURL.pathExtension == "jsonl" else { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            if let modDate = values.contentModificationDate, modDate < since { return nil }
            if let fileSize = values.fileSize, UInt64(fileSize) > maxFileSize {
                Log.warn("Skipping oversized Codex JSONL (\(fileSize / 1_048_576)MB): \(fileURL.lastPathComponent)")
                return nil
            }
            return parseSession(fileURL: fileURL, since: since, until: until)
        }

        return stats(from: summaries)
    }

    private static func stats(from summaries: [CodexSessionSummary]) -> UsageStats {
        let cal = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let modelAgg = summaries.reduce(into: [String: (tokens: TokenUsage, cost: Double)]()) { partial, summary in
            summary.modelUsage.forEach { model, value in
                var existing = partial[model] ?? (tokens: TokenUsage(), cost: 0)
                existing.tokens.add(value.tokens)
                existing.cost += value.cost
                partial[model] = existing
            }
        }

        let dailyAgg = summaries.reduce(into: [String: (date: Date, tokens: TokenUsage, cost: Double, count: Int)]()) { partial, summary in
            let dayStart = cal.startOfDay(for: summary.date)
            let key = dayFormatter.string(from: dayStart)
            var existing = partial[key] ?? (date: dayStart, tokens: TokenUsage(), cost: 0, count: 0)
            existing.tokens.add(summary.tokens)
            existing.cost += summary.cost
            existing.count += summary.messages
            partial[key] = existing
        }

        let projectAgg = summaries.reduce(into: [String: (name: String, cost: Double, messages: Int, sessions: Int)]()) { partial, summary in
            var existing = partial[summary.directoryName] ?? (name: summary.projectName, cost: 0, messages: 0, sessions: 0)
            existing.cost += summary.cost
            existing.messages += summary.messages
            existing.sessions += 1
            partial[summary.directoryName] = existing
        }

        let byModel = modelAgg
            .map { ModelUsage(model: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.cost > $1.cost }

        let daily = dailyAgg.values
            .map { DailyUsage(date: $0.date, tokens: $0.tokens, cost: $0.cost, messageCount: $0.count) }
            .sorted { $0.date > $1.date }

        let byProject = projectAgg
            .map {
                ProjectUsage(
                    projectName: $0.value.name,
                    directoryName: $0.key,
                    totalCost: $0.value.cost,
                    totalMessages: $0.value.messages,
                    sessionCount: $0.value.sessions
                )
            }
            .sorted { $0.totalCost > $1.totalCost }

        var totalTokens = TokenUsage()
        modelAgg.values.forEach { totalTokens.add($0.tokens) }

        return UsageStats(
            totalCost: modelAgg.values.reduce(0) { $0 + $1.cost },
            totalTokens: totalTokens,
            totalMessages: summaries.reduce(0) { $0 + $1.messages },
            sessionCount: summaries.count,
            byModel: byModel,
            daily: daily,
            byProject: byProject
        )
    }

    private static func projectName(from cwd: String) -> String {
        guard cwd != "Codex" else { return cwd }
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? "Codex" : last
    }

    private static func fileDate(_ fileURL: URL) -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
