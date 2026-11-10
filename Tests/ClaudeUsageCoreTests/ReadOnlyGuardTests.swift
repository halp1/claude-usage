import Foundation
import Testing
@testable import ClaudeUsageCore

/// Guards the invariant this project violated once, at real cost.
///
/// Refresh tokens are single-use: renewing Claude Code's `Claude Code-credentials`
/// grant invalidates the refresh token a running Claude Code holds in memory,
/// which logs the user out and puts `/login` into a loop that only deleting the
/// keychain item breaks.
///
/// The app may renew only its own grant (`AppGrant`, created by its own browser
/// sign-in and stored under a different keychain service). These tests fail if
/// a change could let Claude Code's grant be written or renewed.

private let sourcesRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")

private func sources() throws -> [(name: String, text: String)] {
    let files = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []
    return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}

@Test func nothingWritesAKeychainItemThroughTheSecurityFramework() throws {
    let all = try sources()
    #expect(!all.isEmpty, "found no Swift sources to scan; check the path math above")
    for (name, text) in all {
        for token in ["SecItemUpdate", "SecItemAdd", "SecItemDelete", "SecKeychainItemModify"] {
            #expect(!text.contains(token), "\(name) contains \(token); the app must not write keychain items directly")
        }
    }
}

@Test func tokenExchangeLivesOnlyInTheAppGrantClient() throws {
    // `ClaudeOAuth` only accepts an `AppGrant`, which is never built from
    // Claude Code's item. Keep every token exchange in that one file.
    for (name, text) in try sources() where name != "ClaudeOAuth.swift" {
        for token in ["grant_type", "refresh_token", "oauth/token"] {
            #expect(!text.contains(token), "\(name) contains \(token); token exchange belongs in ClaudeOAuth.swift only")
        }
    }
}

@Test func claudeCodesItemIsOnlyEverRead() throws {
    for (name, text) in try sources() {
        if name == "Credentials.swift" {
            // The reader must not pull the refresh token out at all.
            #expect(!text.contains("[\"refreshToken\"]"), "Credentials.swift reads Claude Code's refresh token")
            #expect(!text.contains("add-generic-password") && !text.contains("delete-generic-password"))
        } else {
            #expect(!text.contains("Claude Code-credentials"), "\(name) names Claude Code's keychain item")
            #expect(!text.contains("OAuthCredentials.service"), "\(name) addresses Claude Code's keychain item")
        }
    }
}

@Test func appGrantUsesItsOwnKeychainItem() {
    #expect(KeychainAppGrantStore.service != OAuthCredentials.service)
}

@Test func claudeCodeCredentialsCarryNoRefreshToken() throws {
    let blob = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"SECRET","expiresAt":1789017599542}}"#
    let credentials = try OAuthCredentials(json: Data(blob.utf8))
    let labels = Mirror(reflecting: credentials).children.compactMap(\.label)
    #expect(labels.sorted() == ["accessToken", "expiresAt"])
    #expect(!String(describing: credentials).contains("SECRET"))
}
