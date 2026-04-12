// AuthManager.swift
// Handles OAuth authentication, credential loading, token refresh, and token persistence

import Foundation
import Combine

// MARK: - Credential source

enum CredentialSource: String {
    case file = "credentials.json"
    case keychain = "Keychain"
    case environment = "CLAUDE_CODE_OAUTH_TOKEN"
    case none = "Not found"
}

// MARK: - Auth manager

class AuthManager: ObservableObject {

    @Published var isAuthenticated = false
    @Published var credentialSource: CredentialSource = .none
    @Published var subscriptionType: String = ""

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var tokenExpiresAt: Double?

    private var credentialsWatcher: DispatchSourceFileSystemObject?

    // OAuth refresh is intentionally NOT done by this app.
    // Claude Code manages the single-use refresh token cycle.
    // If we refresh, we invalidate Claude Code's token → user must re-login.

    static let credentialsPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }()

    // MARK: - Credential loading

    func loadCredentials() {
        // 1. File ~/.claude/.credentials.json
        if let data = try? Data(contentsOf: Self.credentialsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            accessToken = token
            refreshToken = oauth["refreshToken"] as? String
            tokenExpiresAt = oauth["expiresAt"] as? Double
            subscriptionType = oauth["subscriptionType"] as? String ?? ""
            credentialSource = .file
            isAuthenticated = true
            Log.info("Credentials loaded from file (type: \(subscriptionType))")
            return
        }

        // 2. Keychain — load off main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keychainJSON = Self.loadFromKeychain()
            DispatchQueue.main.async {
                guard let self else { return }
                if let keychainJSON,
                   let oauth = keychainJSON["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String, !token.isEmpty {
                    self.accessToken = token
                    self.refreshToken = oauth["refreshToken"] as? String
                    self.tokenExpiresAt = oauth["expiresAt"] as? Double
                    self.subscriptionType = oauth["subscriptionType"] as? String ?? ""
                    self.credentialSource = .keychain
                    self.isAuthenticated = true
                    Log.info("Credentials loaded from Keychain (type: \(self.subscriptionType))")
                    return
                }

                // 3. Environment variable
                if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
                   !envToken.isEmpty {
                    self.accessToken = envToken
                    self.credentialSource = .environment
                    self.isAuthenticated = true
                    Log.info("Credentials loaded from environment")
                    return
                }

                self.credentialSource = .none
                self.isAuthenticated = false
                Log.warn("No credentials found")
            }
        }
    }

    // MARK: - Token management

    var tokenNeedsRefresh: Bool {
        guard let expiresAt = tokenExpiresAt else { return true }
        let expiresDate = Date(timeIntervalSince1970: expiresAt / 1000)
        return Date().addingTimeInterval(5 * 60) >= expiresDate
    }

    var tokenExpired: Bool {
        guard let expiresAt = tokenExpiresAt else { return false }
        let expiresDate = Date(timeIntervalSince1970: expiresAt / 1000)
        return Date() >= expiresDate
    }

    /// Reload credentials from disk first, then keychain as fallback.
    /// On macOS, Claude Code may store credentials exclusively in keychain
    /// (deleting .credentials.json), so we must check both sources.
    func reloadCredentials(completion: @escaping (Bool) -> Void) {
        let previousToken = accessToken

        // 1. Try file first
        if let data = try? Data(contentsOf: Self.credentialsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            accessToken = token
            refreshToken = oauth["refreshToken"] as? String
            tokenExpiresAt = oauth["expiresAt"] as? Double
            subscriptionType = oauth["subscriptionType"] as? String ?? ""
            credentialSource = .file
            isAuthenticated = true
            let changed = accessToken != previousToken
            if changed { Log.info("Credentials reloaded from file") }
            completion(true)
            return
        }

        // 2. Fallback to keychain (off main thread)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keychainJSON = Self.loadFromKeychain()
            DispatchQueue.main.async {
                guard let self else { return }
                if let keychainJSON,
                   let oauth = keychainJSON["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String, !token.isEmpty {
                    self.accessToken = token
                    self.refreshToken = oauth["refreshToken"] as? String
                    self.tokenExpiresAt = oauth["expiresAt"] as? Double
                    self.subscriptionType = oauth["subscriptionType"] as? String ?? ""
                    self.credentialSource = .keychain
                    self.isAuthenticated = true
                    let changed = self.accessToken != previousToken
                    if changed { Log.info("Credentials reloaded from Keychain") }
                    completion(true)
                } else {
                    Log.warn("No credentials found in file or Keychain")
                    completion(self.isAuthenticated)
                }
            }
        }
    }

    // MARK: - Credentials file watcher

    func startWatchingCredentials() {
        stopWatchingCredentials()

        let path = Self.credentialsPath.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Small delay to let the file finish writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let wasAuthenticated = self.isAuthenticated
                self.loadCredentials()
                if !wasAuthenticated && self.isAuthenticated {
                    Log.info("Credentials detected via file watcher")
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        credentialsWatcher = source
    }

    private func stopWatchingCredentials() {
        credentialsWatcher?.cancel()
        credentialsWatcher = nil
    }

    deinit {
        stopWatchingCredentials()
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let rawData = pipe.fileHandleForReading.readDataToEndOfFile()
            // Trim whitespace from raw output before parsing
            guard let trimmed = String(data: rawData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return nil }

            return json
        } catch {
            return nil
        }
    }
}
