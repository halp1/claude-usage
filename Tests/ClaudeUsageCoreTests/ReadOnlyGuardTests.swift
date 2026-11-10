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
/// The app renews only grants from its own browser sign-in. These tests fail if
/// a change could let Claude Code's grant be read, written, or renewed.

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
    // Keep every token exchange in the one file that handles the app's own grants.
    for (name, text) in try sources() where name != "ClaudeOAuth.swift" {
        for token in ["grant_type", "refresh_token", "oauth/token"] {
            #expect(!text.contains(token), "\(name) contains \(token); token exchange belongs in ClaudeOAuth.swift only")
        }
    }
}

@Test func neverTouchesClaudeCodesLogin() throws {
    // The app signs in on its own. Reading Claude Code's item once tied the
    // app to Claude Code's sign-in, and renewing it logged Claude Code out.
    for (name, text) in try sources() {
        #expect(!text.contains("Claude Code-credentials"), "\(name) names Claude Code's keychain item")
        #expect(!text.contains("claudeAiOauth"), "\(name) parses Claude Code's credential blob")
    }
}
