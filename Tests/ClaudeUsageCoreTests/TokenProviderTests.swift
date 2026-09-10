import Foundation
import Testing
@testable import ClaudeUsageCore

/// An in-memory stand-in for the keychain. Records writes so tests can assert
/// the provider never performs one.
private final class FakeStore: CredentialStore, @unchecked Sendable {
    var credentials: OAuthCredentials
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    init(expiresIn seconds: TimeInterval, accessToken: String = "initial") {
        credentials = OAuthCredentials(
            accessToken: accessToken,
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(seconds)
        )
    }

    func load() throws -> OAuthCredentials {
        loadCount += 1
        return credentials
    }

    func save(_ credentials: OAuthCredentials) throws {
        saveCount += 1
        self.credentials = credentials
    }
}

/// Stands in for the Claude Code CLI, optionally simulating a successful renewal.
private final class FakeRenewer: CredentialRenewing, @unchecked Sendable {
    private(set) var renewCount = 0
    private let onRenew: (@Sendable () -> Void)?

    init(onRenew: (@Sendable () -> Void)? = nil) {
        self.onRenew = onRenew
    }

    func renew() async {
        renewCount += 1
        onRenew?()
    }
}

@Test func usesTheStoredTokenAndDoesNotInvokeTheCLIWhenItIsFresh() async throws {
    let store = FakeStore(expiresIn: 3600)
    let renewer = FakeRenewer()
    let provider = TokenProvider(store: store, renewer: renewer)

    #expect(try await provider.accessToken() == "initial")
    // Renewal is the expensive, sensitive path: it must stay untouched here.
    #expect(renewer.renewCount == 0)
    #expect(store.saveCount == 0)
}

@Test func asksTheCLIToRenewThenRereadsWhenTheTokenHasExpired() async throws {
    let store = FakeStore(expiresIn: -10)
    let renewer = FakeRenewer()
    // Simulate Claude Code rewriting the keychain during `auth status`.
    let provider = TokenProvider(store: store, renewer: FakeRenewer {
        store.credentials = OAuthCredentials(
            accessToken: "renewed",
            refreshToken: "rotated",
            expiresAt: Date().addingTimeInterval(3600)
        )
    })

    #expect(try await provider.accessToken() == "renewed")
    // The app itself must never write the shared item; only the CLI does.
    #expect(store.saveCount == 0)
    _ = renewer
}

@Test func reportsExpiryWhenTheCLICouldNotRenew() async {
    let store = FakeStore(expiresIn: -10)
    let renewer = FakeRenewer()
    let provider = TokenProvider(store: store, renewer: renewer)

    await #expect(throws: TokenError.self) {
        _ = try await provider.accessToken()
    }
    #expect(renewer.renewCount == 1)
    #expect(store.saveCount == 0)
}

@Test func forcedRenewalRunsEvenWhileTheStoredTokenLooksValid() async throws {
    let store = FakeStore(expiresIn: 3600)
    let renewer = FakeRenewer()
    let provider = TokenProvider(store: store, renewer: renewer)

    // Recovery path after a 401 the expiry timestamp did not predict.
    _ = try await provider.accessToken(forceRenewal: true)
    #expect(renewer.renewCount == 1)
    #expect(store.saveCount == 0)
}

@Test func locatesTheClaudeExecutable() {
    // The renewal path is inert without this; a missing CLI degrades to stale
    // values rather than failing loudly, so assert it resolves on this machine.
    #expect(ClaudeCLIRenewer.executableURL() != nil)
}
