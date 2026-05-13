// CodexUsageManager.swift
//
// Personal-fork addition. Mirrors UsageManager for OpenAI's Codex CLI.
//
// Architecture parity with the Claude side:
//
//   Claude                                 Codex
//   ------------------------------------   ------------------------------------
//   ~/.claude/.credentials.json (auth)     ~/.codex/auth.json (auth)
//   api.anthropic.com/api/oauth/usage      chatgpt.com/backend-api/wham/usage
//   OAuthUsageResponse                     CodexRateLimitSnapshot list
//   5h session + 7d windows + per-model    primary (5h) + secondary (7d) windows
//
// Response schema is mirrored from openai/codex's
//   codex-rs/protocol/src/protocol.rs (RateLimitSnapshot, RateLimitWindow)
// and the URL/header conventions from
//   codex-rs/backend-client/src/client.rs (get_rate_limits_many, headers()).
//
// v1 scope: read auth file → call API → expose quotas array compatible with
// UsageQuota so the existing quota-card UI components work unmodified.
// Deferred: token refresh on 401 (user must run `codex` to refresh), JSONL
// transcript parsing for analytics, auto-refresh timer.

import Foundation
import Combine

// MARK: - auth.json model

private struct CodexAuthFile: Decodable {
    let auth_mode: String?
    let tokens: Tokens?

    struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let account_id: String?
    }
}

// MARK: - /wham/usage response model
//
// Wire format observed against an active ChatGPT-subscription Codex account.
// Field names match the OpenAPI-generated schema in openai/codex's
// `codex-backend-openapi-models/src/models/rate_limit_window_snapshot.rs`,
// not the internal Rust `protocol.rs` types (which use different names).
//
// Sample shape:
// {
//   "user_id": "user-...", "account_id": "user-...", "email": "...",
//   "plan_type": "prolite",
//   "rate_limit": {
//     "allowed": true, "limit_reached": false,
//     "primary_window":   { "used_percent": 17, "limit_window_seconds": 18000,
//                           "reset_after_seconds": 13125, "reset_at": 1778640826 },
//     "secondary_window": { ... 604800-second window ... }
//   },
//   "code_review_rate_limit": null,
//   "additional_rate_limits": [
//     { "limit_name": "GPT-5.3-Codex-Spark",
//       "metered_feature": "codex_bengalfox",
//       "rate_limit": { "primary_window": {...}, "secondary_window": {...} }}
//   ],
//   "credits": { ... }, "spend_control": { ... }
// }

private struct CodexRateLimitWindow: Decodable {
    let used_percent: Double
    let limit_window_seconds: Int?
    let reset_after_seconds: Int?
    let reset_at: Int64?
}

private struct CodexRateLimit: Decodable {
    let allowed: Bool?
    let limit_reached: Bool?
    let primary_window: CodexRateLimitWindow?
    let secondary_window: CodexRateLimitWindow?
}

private struct CodexAdditionalLimit: Decodable {
    let limit_name: String?
    let metered_feature: String?
    let rate_limit: CodexRateLimit?
}

private struct CodexCredits: Decodable {
    let has_credits: Bool?
    let unlimited: Bool?
    let balance: String?
}

private struct CodexUsageResponse: Decodable {
    let plan_type: String?
    let rate_limit: CodexRateLimit?
    let code_review_rate_limit: CodexRateLimit?
    let additional_rate_limits: [CodexAdditionalLimit]?
    let credits: CodexCredits?
}

// MARK: - Manager

final class CodexUsageManager: ObservableObject {

    // MARK: - Published state (mirrors UsageManager surface)

    @Published var quotas: [UsageQuota] = []
    @Published var isLoading: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?

    // MARK: - Config

    private static let authFilePath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".codex/auth.json")
    }()

    private static let chatgptUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static let refreshInterval: TimeInterval = 120 // 2 min, matches Claude side

    private var refreshTimer: Timer?

    init() {
        refresh()
        scheduleAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public API

    func refresh() {
        guard let auth = loadAuth() else {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.errorMessage = "Codex auth missing. Run `codex` to sign in."
                self.quotas = []
            }
            return
        }
        guard let tokens = auth.tokens, !tokens.access_token.isEmpty else {
            DispatchQueue.main.async {
                self.isAuthenticated = false
                self.errorMessage = "Codex auth has no access_token. Re-run `codex` to refresh."
                self.quotas = []
            }
            return
        }

        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.isLoading = true
            self.errorMessage = nil
        }

        var request = URLRequest(url: Self.chatgptUsageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens.account_id, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                self.lastRefresh = Date()

                if let error = error {
                    self.errorMessage = "Codex usage fetch failed: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.errorMessage = "Codex usage: no response"
                    return
                }
                switch http.statusCode {
                case 200:
                    self.applyResponse(data: data)
                case 401, 403:
                    // v1: don't implement OAuth refresh. Tell the user how to recover.
                    self.errorMessage = "Codex auth expired. Run `codex` once to refresh tokens."
                    self.quotas = []
                case 429:
                    self.errorMessage = "Codex API rate-limited; will retry next cycle."
                default:
                    let preview = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
                    self.errorMessage = "Codex usage HTTP \(http.statusCode): \(preview)"
                }
            }
        }.resume()
    }

    // MARK: - Internal

    private func loadAuth() -> CodexAuthFile? {
        let url = URL(fileURLWithPath: Self.authFilePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private func applyResponse(data: Data) {
        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            errorMessage = "Codex usage: parse failed (\(error.localizedDescription)). Body: \(preview)"
            return
        }

        var built: [UsageQuota] = []

        // Main rate_limit → "Session" + "Weekly" quotas
        if let main = response.rate_limit {
            if let p = main.primary_window {
                built.append(UsageQuota(
                    label: "Session (\(formatWindow(seconds: p.limit_window_seconds)))",
                    icon: "bolt.fill",
                    utilization: p.used_percent,
                    resetsAt: p.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ))
            }
            if let s = main.secondary_window {
                built.append(UsageQuota(
                    label: "Weekly (\(formatWindow(seconds: s.limit_window_seconds)))",
                    icon: "calendar",
                    utilization: s.used_percent,
                    resetsAt: s.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ))
            }
        }

        // Feature-scoped limits (e.g., "GPT-5.3-Codex-Spark")
        for extra in response.additional_rate_limits ?? [] {
            guard let limit = extra.rate_limit,
                  let name = extra.limit_name else { continue }
            if let p = limit.primary_window {
                built.append(UsageQuota(
                    label: "\(name) (\(formatWindow(seconds: p.limit_window_seconds)))",
                    icon: "sparkle",
                    utilization: p.used_percent,
                    resetsAt: p.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ))
            }
        }

        // Code-review quota if present
        if let cr = response.code_review_rate_limit, let p = cr.primary_window {
            built.append(UsageQuota(
                label: "Code Review (\(formatWindow(seconds: p.limit_window_seconds)))",
                icon: "checkmark.shield",
                utilization: p.used_percent,
                resetsAt: p.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }

        quotas = built
        if built.isEmpty {
            errorMessage = "Codex usage response had no rate-limit windows. Plan: \(response.plan_type ?? "unknown")"
        } else {
            errorMessage = nil
        }
    }

    /// Format the `limit_window_seconds` integer into a compact label like "5h", "7d".
    private func formatWindow(seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "rolling" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func scheduleAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Burn-rate projections (mirrors UsageManager pattern)

    /// Find the session-window quota by label match. Lightweight; no caching.
    private var sessionQuota: UsageQuota? {
        quotas.first(where: { $0.label.lowercased().contains("session") })
    }

    private var weeklyQuota: UsageQuota? {
        quotas.first(where: { $0.label.lowercased().contains("weekly") })
    }

    private func projectLimit(
        for quota: UsageQuota?,
        windowDuration: TimeInterval,
        minElapsed: TimeInterval,
        minUtilization: Double
    ) -> UsageManager.LimitProjection {
        guard let q = quota,
              let resetsAt = q.resetsAt,
              q.utilization > minUtilization else { return .insufficientData }

        let timeRemaining = resetsAt.timeIntervalSinceNow
        let timeElapsed = windowDuration - timeRemaining

        guard timeElapsed > minElapsed else { return .insufficientData }

        let ratePerSecond = q.utilization / timeElapsed
        guard ratePerSecond > 0 else { return .insufficientData }

        let remainingPercent = 100 - q.utilization
        let secondsToLimit = remainingPercent / ratePerSecond

        if secondsToLimit > timeRemaining { return .safe }

        let days = Int(secondsToLimit) / (24 * 3600)
        let hours = (Int(secondsToLimit) % (24 * 3600)) / 3600
        let minutes = (Int(secondsToLimit) % 3600) / 60

        let label: String
        if days > 0 {
            label = "~\(days)d \(hours)h"
        } else if hours > 0 {
            label = "~\(hours)h \(minutes)m"
        } else {
            label = "~\(minutes)m"
        }
        return .approaching(label: label, secondsToLimit: secondsToLimit)
    }

    var sessionLimitProjection: UsageManager.LimitProjection {
        projectLimit(for: sessionQuota, windowDuration: 5 * 3600, minElapsed: 300, minUtilization: 5)
    }

    var weeklyLimitProjection: UsageManager.LimitProjection {
        projectLimit(for: weeklyQuota, windowDuration: 7 * 24 * 3600, minElapsed: 1800, minUtilization: 2)
    }

    var mostUrgentApproaching: (window: String, label: String, secondsToLimit: TimeInterval)? {
        let candidates: [(String, UsageManager.LimitProjection)] = [
            ("Session", sessionLimitProjection),
            ("Weekly", weeklyLimitProjection)
        ]
        let approaching = candidates.compactMap { name, proj -> (String, String, TimeInterval)? in
            if case .approaching(let label, let secs) = proj { return (name, label, secs) }
            return nil
        }
        return approaching.min(by: { $0.2 < $1.2 }).map {
            (window: $0.0, label: $0.1, secondsToLimit: $0.2)
        }
    }

    var allWindowsSafe: Bool {
        let projections = [sessionLimitProjection, weeklyLimitProjection]
        let anyApproaching = projections.contains {
            if case .approaching = $0 { return true }
            return false
        }
        let anySafe = projections.contains {
            if case .safe = $0 { return true }
            return false
        }
        return !anyApproaching && anySafe
    }

    /// Outage forecast for Codex's most-urgent approaching window — mirrors
    /// UsageManager.OutageForecast / mostUrgentOutage but scoped to Codex
    /// quotas. nil when no window is approaching or the math yields a
    /// non-positive outage.
    var mostUrgentOutage: UsageManager.OutageForecast? {
        guard let urgent = mostUrgentApproaching else { return nil }
        let quotaForWindow: UsageQuota? = {
            switch urgent.window {
            case "Session": return sessionQuota
            case "Weekly":  return weeklyQuota
            default:        return nil
            }
        }()
        guard let q = quotaForWindow, let resetsAt = q.resetsAt else { return nil }
        let hitAt = Date(timeIntervalSinceNow: urgent.secondsToLimit)
        let offline = resetsAt.timeIntervalSince(hitAt)
        guard offline > 0 else { return nil }
        return UsageManager.OutageForecast(
            window: urgent.window,
            timeToLimit: urgent.secondsToLimit,
            hitAt: hitAt,
            resumesAt: resetsAt,
            offlineDuration: offline
        )
    }

    var burnRateUnavailableReason: String? {
        if case .insufficientData = sessionLimitProjection,
           case .insufficientData = weeklyLimitProjection {
            return "Need a few minutes of active usage in the current window to project a limit."
        }
        return nil
    }
}
