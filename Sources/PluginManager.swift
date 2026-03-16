// PluginManager.swift
// Reads local Claude Code plugin marketplace data and manages plugin install/uninstall/toggle

import Foundation

// MARK: - Models

struct MarketplacePlugin: Identifiable {
    let name: String
    let description: String
    let version: String
    let category: String
    let marketplace: String
    var installCount: Int = 0
    var isInstalled: Bool = false
    var isEnabled: Bool = false
    var installedVersion: String?

    var id: String { "\(name)@\(marketplace)" }

    var displayCategory: String {
        category.isEmpty ? "other" : category
    }
}

// MARK: - Decodable helpers

private struct InstallCountsFile: Decodable {
    let counts: [PluginCount]

    struct PluginCount: Decodable {
        let plugin: String
        let unique_installs: Int
    }
}

private struct InstalledPluginsFile: Decodable {
    let plugins: [String: [InstalledEntry]]

    struct InstalledEntry: Decodable {
        let version: String
    }
}

private struct MarketplaceFile: Decodable {
    let name: String
    let plugins: [MarketplaceEntry]

    struct MarketplaceEntry: Decodable {
        let name: String
        let description: String?
        let version: String?
        let category: String?
    }
}

// MARK: - Manager

class PluginManager: ObservableObject {

    @Published var availablePlugins: [MarketplacePlugin] = []
    @Published var categories: [String] = []
    @Published var selectedCategory: String?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isInstalling: String?

    private static let pluginsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins")
    }()

    private static let settingsPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }()

    // MARK: - Computed

    var filteredPlugins: [MarketplacePlugin] {
        availablePlugins.filter { plugin in
            let matchesSearch = searchText.isEmpty ||
                plugin.name.localizedCaseInsensitiveContains(searchText) ||
                plugin.description.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || plugin.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    var installedPlugins: [MarketplacePlugin] {
        availablePlugins.filter(\.isInstalled)
    }

    // MARK: - Load data

    func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.loadPluginData()
            DispatchQueue.main.async {
                self.availablePlugins = result.plugins
                self.categories = result.categories
                self.isLoading = false
            }
        }
    }

    private struct LoadResult {
        let plugins: [MarketplacePlugin]
        let categories: [String]
    }

    private static func loadPluginData() -> LoadResult {
        let fm = FileManager.default
        var plugins: [MarketplacePlugin] = []

        // 1. Load all marketplace.json files
        let marketplacesDir = pluginsDir.appendingPathComponent("marketplaces")
        if let marketplaces = try? fm.contentsOfDirectory(atPath: marketplacesDir.path) {
            for marketplace in marketplaces {
                let jsonPath = marketplacesDir
                    .appendingPathComponent(marketplace)
                    .appendingPathComponent(".claude-plugin/marketplace.json")
                guard let data = try? Data(contentsOf: jsonPath),
                      let file = try? JSONDecoder().decode(MarketplaceFile.self, from: data) else { continue }

                for entry in file.plugins {
                    plugins.append(MarketplacePlugin(
                        name: entry.name,
                        description: entry.description ?? "",
                        version: entry.version ?? "1.0.0",
                        category: entry.category ?? "",
                        marketplace: file.name
                    ))
                }
            }
        }

        // 2. Merge install counts
        let countsPath = pluginsDir.appendingPathComponent("install-counts-cache.json")
        if let data = try? Data(contentsOf: countsPath),
           let counts = try? JSONDecoder().decode(InstallCountsFile.self, from: data) {
            let lookup = Dictionary(uniqueKeysWithValues: counts.counts.map { ($0.plugin, $0.unique_installs) })
            for i in plugins.indices {
                plugins[i].installCount = lookup[plugins[i].id] ?? 0
            }
        }

        // 3. Merge installed state
        let installedPath = pluginsDir.appendingPathComponent("installed_plugins.json")
        if let data = try? Data(contentsOf: installedPath),
           let installed = try? JSONDecoder().decode(InstalledPluginsFile.self, from: data) {
            for i in plugins.indices {
                if let entries = installed.plugins[plugins[i].id], let entry = entries.first {
                    plugins[i].isInstalled = true
                    plugins[i].installedVersion = entry.version
                }
            }
        }

        // 4. Merge enabled state
        if let data = try? Data(contentsOf: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let enabled = json["enabledPlugins"] as? [String: Bool] {
            for i in plugins.indices {
                plugins[i].isEnabled = enabled[plugins[i].id] ?? false
            }
        }

        // 5. Sort by install count descending
        plugins.sort { $0.installCount > $1.installCount }

        // 6. Extract categories
        let categories = Array(Set(plugins.compactMap { $0.category.isEmpty ? nil : $0.category })).sorted()

        return LoadResult(plugins: plugins, categories: categories)
    }

    // MARK: - Plugin actions

    func installPlugin(_ plugin: MarketplacePlugin) {
        isInstalling = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = Self.runClaude(arguments: ["plugin", "install", "\(plugin.name)@\(plugin.marketplace)"])
            DispatchQueue.main.async {
                self?.isInstalling = nil
                if success { self?.refresh() }
            }
        }
    }

    func uninstallPlugin(_ plugin: MarketplacePlugin) {
        isInstalling = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = Self.runClaude(arguments: ["plugin", "uninstall", "\(plugin.name)@\(plugin.marketplace)"])
            DispatchQueue.main.async {
                self?.isInstalling = nil
                if success { self?.refresh() }
            }
        }
    }

    func togglePlugin(_ plugin: MarketplacePlugin, enabled: Bool) {
        guard let data = try? Data(contentsOf: Self.settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var enabledPlugins = json["enabledPlugins"] as? [String: Bool] ?? [:]
        enabledPlugins[plugin.id] = enabled
        json["enabledPlugins"] = enabledPlugins
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: Self.settingsPath)
        }
        if let idx = availablePlugins.firstIndex(where: { $0.id == plugin.id }) {
            availablePlugins[idx].isEnabled = enabled
        }
    }

    // MARK: - CLI

    private static func runClaude(arguments: [String]) -> Bool {
        let process = Process()
        let claudePaths = [
            "/usr/local/bin/claude",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        ]
        guard let claudePath = claudePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            Log.error("claude binary not found")
            return false
        }
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.error("Failed to run claude: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    static func formatInstallCount(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
