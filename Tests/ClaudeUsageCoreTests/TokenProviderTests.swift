import Foundation
import Testing
@testable import ClaudeUsageCore

/// Claude Code's item, read-only. Counts reads; it has no write path to count.
private final class FakeClaudeCode: CredentialStore, @unchecked Sendable {
    var credentials: OAuthCredentials?
    private(set) var loadCount = 0

    init(expiresIn seconds: TimeInterval?, accessToken: String = "borrowed") {
        credentials = seconds.map { OAuthCredentials(accessToken: accessToken, expiresAt: Date().addingTimeInterval($0)) }
    }

    func load() throws -> OAuthCredentials {
        loadCount += 1
        guard let credentials else { throw CredentialsError.notFound }
        return credentials
    }
}

private final class FakeGrants: AppGrantStoring, @unchecked Sendable {
    var grant: AppGrant?
    private(set) var saveCount = 0

    init(_ grant: AppGrant? = nil) { self.grant = grant }

    func load() throws -> AppGrant? { grant }
    func save(_ grant: AppGrant) throws { saveCount += 1; self.grant = grant }
    func clear() throws { grant = nil }
}

private final class FakeRefresher: GrantRefreshing, @unchecked Sendable {
    private(set) var refreshed: [String] = []
    var reject = false

    func refresh(_ grant: AppGrant) async throws -> AppGrant {
        refreshed.append(grant.refreshToken)
        try await Task.sleep(for: .milliseconds(20))
        if reject { throw OAuthError.grantRejected }
        return AppGrant(accessToken: "renewed", refreshToken: "rotated", expiresAt: Date().addingTimeInterval(3600))
    }
}

private func grant(expiresIn seconds: TimeInterval) -> AppGrant {
    AppGrant(accessToken: "own", refreshToken: "own-refresh", expiresAt: Date().addingTimeInterval(seconds))
}

@Test func usesTheOwnGrantWithoutTouchingClaudeCode() async throws {
    let claude = FakeClaudeCode(expiresIn: 3600)
    let refresher = FakeRefresher()
    let provider = TokenProvider(claudeCode: claude, grants: FakeGrants(grant(expiresIn: 3600)), refresher: refresher)

    #expect(try await provider.accessToken() == "own")
    #expect(claude.loadCount == 0)
    #expect(refresher.refreshed.isEmpty)
}

@Test func renewsTheOwnGrantWhenItExpiresAndSavesTheRotatedToken() async throws {
    let grants = FakeGrants(grant(expiresIn: -10))
    let refresher = FakeRefresher()
    let provider = TokenProvider(claudeCode: FakeClaudeCode(expiresIn: nil), grants: grants, refresher: refresher)

    #expect(try await provider.accessToken() == "renewed")
    #expect(refresher.refreshed == ["own-refresh"])
    #expect(grants.grant?.refreshToken == "rotated")
}

@Test func concurrentCallersShareOneRenewal() async throws {
    // A single-use refresh token must be spent exactly once.
    let grants = FakeGrants(grant(expiresIn: -10))
    let refresher = FakeRefresher()
    let provider = TokenProvider(claudeCode: FakeClaudeCode(expiresIn: nil), grants: grants, refresher: refresher)

    async let a = provider.accessToken()
    async let b = provider.accessToken()
    async let c = provider.accessToken(forceRenewal: true)
    _ = try await (a, b, c)
    #expect(refresher.refreshed == ["own-refresh"])
    #expect(grants.saveCount == 1)
}

@Test func borrowsClaudeCodesTokenOnlyWhileItIsValid() async throws {
    let refresher = FakeRefresher()
    let provider = TokenProvider(claudeCode: FakeClaudeCode(expiresIn: 3600), grants: FakeGrants(), refresher: refresher)
    #expect(try await provider.accessToken() == "borrowed")
    #expect(refresher.refreshed.isEmpty)
}

@Test func expiredClaudeCodeTokenAsksForSignInAndIsNeverRenewed() async {
    let refresher = FakeRefresher()
    let provider = TokenProvider(claudeCode: FakeClaudeCode(expiresIn: -10), grants: FakeGrants(), refresher: refresher)

    await #expect(throws: TokenError.signInRequired) {
        _ = try await provider.accessToken()
    }
    await #expect(throws: TokenError.signInRequired) {
        _ = try await provider.accessToken(forceRenewal: true)
    }
    // The only refresher in the app was never called for Claude Code's login.
    #expect(refresher.refreshed.isEmpty)
}

@Test func rejectedOwnGrantFallsBackToAValidBorrowedToken() async throws {
    let refresher = FakeRefresher()
    refresher.reject = true
    let provider = TokenProvider(
        claudeCode: FakeClaudeCode(expiresIn: 3600),
        grants: FakeGrants(grant(expiresIn: -10)),
        refresher: refresher
    )
    #expect(try await provider.accessToken() == "borrowed")
}

@Test func parsesATokenResponseAndKeepsTheOldRefreshTokenIfNoneIsReturned() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let rotated = try ClaudeOAuth.parseGrant(
        Data(#"{"access_token":"a","refresh_token":"r2","expires_in":28800}"#.utf8),
        previousRefreshToken: "r1", now: now
    )
    #expect(rotated == AppGrant(accessToken: "a", refreshToken: "r2", expiresAt: now.addingTimeInterval(28800)))

    let kept = try ClaudeOAuth.parseGrant(
        Data(#"{"access_token":"a","expires_in":60}"#.utf8),
        previousRefreshToken: "r1", now: now
    )
    #expect(kept.refreshToken == "r1")
}

@Test func pkceChallengeIsBase64URLSHA256() {
    // Expected value computed independently with Python's hashlib.
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mJ92K9mlQo7Y1vDB2fLQ0ZL0Iv5U0E") == "u_oFNzlVM7I7dTfOzb4DXJIxq6M668Lg4FpmaWZ-9Kg")
}

@Test func authorizationURLMatchesDSHsKnownGoodRequest() {
    let url = ClaudeOAuth().authorizationURL(challenge: "c", state: "s", redirectURI: SignIn.redirectURI)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.first { $0.name == "scope" }?.value
        == "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
    #expect(PKCE.randomURLSafe().count == 43)
    #expect(items.first { $0.name == "redirect_uri" }?.value == "http://localhost:53692/callback")
}
