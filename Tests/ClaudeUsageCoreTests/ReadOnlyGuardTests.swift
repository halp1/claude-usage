import Foundation
import Testing

/// Guards the invariant this project violated once, at real cost.
///
/// Refresh tokens are single-use: renewing the shared `Claude Code-credentials`
/// grant invalidates the refresh token a running Claude Code holds in memory,
/// which logs the user out and puts `/login` into a loop that only deleting the
/// keychain item breaks. Reading that item is safe; writing it or refreshing
/// against it is not, at any interval, with any locking.
///
/// This app therefore reads and never writes. If a future change reaches for a
/// keychain write or a token refresh, this test fails and explains why.
@Test func sourcesNeverWriteTheSharedCredentialItem() throws {
    // Tests/ClaudeUsageCoreTests/ReadOnlyGuardTests.swift → repository root
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")

    let forbidden = [
        "SecItemUpdate": "writes the shared keychain item",
        "SecItemAdd": "writes the shared keychain item",
        "SecItemDelete": "destroys the shared keychain item",
        "grant_type": "performs an OAuth token exchange",
        "refresh_token": "rotates the shared refresh token",
    ]

    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []
    #expect(!files.isEmpty, "found no Swift sources to scan; check the path math above")

    for file in files {
        let contents = try String(contentsOf: file, encoding: .utf8)
        for (token, reason) in forbidden {
            #expect(
                !contents.contains(token),
                """
                \(file.lastPathComponent) contains \(token), which \(reason).
                The menu bar app must only read Claude Code's credentials. \
                Renewing that grant rotates the refresh token and logs the user \
                out of Claude Code. To survive token expiry, use a separate \
                credential from `claude setup-token` in this app's own keychain \
                item instead.
                """
            )
        }
    }
}
