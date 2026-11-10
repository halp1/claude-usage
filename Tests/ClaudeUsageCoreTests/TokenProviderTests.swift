import Foundation
import Testing
@testable import ClaudeUsageCore

/// Fakes are hit from concurrent tasks, so every access holds a lock.
private final class FakeAccounts: AccountStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Account]

    init(_ accounts: [Account] = []) { stored = accounts }

    var accounts: [Account] { lock.withLock { stored } }

    func list() throws -> [Account] { lock.withLock { stored.sorted { $0.addedAt < $1.addedAt } } }
    func save(_ account: Account) throws {
        lock.withLock {
            stored.removeAll { $0.key == account.key }
            stored.append(account)
        }
    }
    func remove(key: String) throws { lock.withLock { stored.removeAll { $0.key == key } } }
}

private final class FakeOAuth: GrantRefreshing, ProfileLooking, @unchecked Sendable {
    private let lock = NSLock()
    private var spent: [String] = []
    let rejected: Set<String>
    let owners: [String: String]

    init(rejected: Set<String> = [], owners: [String: String] = [:]) {
        self.rejected = rejected
        self.owners = owners
    }

    var refreshed: [String] { lock.withLock { spent } }

    func refresh(_ grant: AppGrant) async throws -> AppGrant {
        lock.withLock { spent.append(grant.refreshToken) }
        try await Task.sleep(for: .milliseconds(20))
        if rejected.contains(grant.refreshToken) { throw OAuthError.grantRejected }
        return AppGrant(accessToken: "\(grant.accessToken)+", refreshToken: "\(grant.refreshToken)+", expiresAt: Date().addingTimeInterval(3600))
    }

    func profile(accessToken: String) async throws -> AccountProfile {
        guard let email = owners[accessToken] else { throw OAuthError.requestFailed(status: 401) }
        return AccountProfile(email: email, organization: "Org")
    }
}

private func account(_ key: String, email: String? = nil, expiresIn: TimeInterval = 3600, signInEndsIn: TimeInterval? = nil, order: TimeInterval = 0) -> Account {
    Account(
        key: key,
        email: email,
        organization: nil,
        grant: AppGrant(
            accessToken: "\(key)-at",
            refreshToken: "\(key)-rt",
            expiresAt: Date().addingTimeInterval(expiresIn),
            refreshExpiresAt: signInEndsIn.map { Date().addingTimeInterval($0) }
        ),
        addedAt: Date(timeIntervalSince1970: order)
    )
}

@Test func renewsOnlyTheExpiredAccountAndKeepsEachRenewalSeparate() async throws {
    let store = FakeAccounts([account("a", expiresIn: -10, order: 1), account("b", order: 2), account("c", expiresIn: -10, order: 3)])
    let oauth = FakeOAuth()
    let provider = TokenProvider(store: store, refresher: oauth, profiles: oauth)

    // Concurrent callers on one account share one renewal: a single-use
    // refresh token must be spent exactly once.
    async let a1 = provider.accessToken(for: "a")
    async let a2 = provider.accessToken(for: "a", forceRenewal: true)
    async let b = provider.accessToken(for: "b")
    async let c = provider.accessToken(for: "c")
    let tokens = try await [a1, a2, b, c]

    #expect(tokens == ["a-at+", "a-at+", "b-at", "c-at+"])
    #expect(oauth.refreshed.sorted() == ["a-rt", "c-rt"])
    #expect(store.accounts.first { $0.key == "a" }?.grant.refreshToken == "a-rt+")
}

@Test func anExpiredSignInAsksForThatAccountOnlyAndIsNotSpent() async throws {
    let store = FakeAccounts([
        account("old", email: "old@example.com", expiresIn: -10, signInEndsIn: -1, order: 1),
        account("rejected", email: "gone@example.com", expiresIn: -10, order: 2),
    ])
    let oauth = FakeOAuth(rejected: ["rejected-rt"])
    let provider = TokenProvider(store: store, refresher: oauth, profiles: oauth)

    await #expect(throws: TokenError.signInExpired(email: "old@example.com")) {
        _ = try await provider.accessToken(for: "old")
    }
    await #expect(throws: TokenError.signInExpired(email: "gone@example.com")) {
        _ = try await provider.accessToken(for: "rejected")
    }
    #expect(oauth.refreshed == ["rejected-rt"], "a sign-in past its end is not sent to the server")
    #expect(store.accounts.count == 2, "a failed account is kept so it can be signed in again")
}

@Test func signingInAgainReplacesTheSameAccountAndSupersedesTheLegacyGrant() async throws {
    // An unlabeled grant from an older version, owned by me@example.com.
    let legacy = account("halp", order: 1)
    let store = FakeAccounts([legacy])
    let oauth = FakeOAuth(owners: ["halp-at": "me@example.com"])
    let provider = TokenProvider(store: store, refresher: oauth, profiles: oauth)
    let fresh = AppGrant(accessToken: "new-at", refreshToken: "new-rt", expiresAt: Date().addingTimeInterval(3600))

    try await provider.add(grant: fresh, profile: AccountProfile(email: "Me@Example.com", organization: "Org"))
    #expect(store.accounts.map(\.key) == ["Me@Example.com"], "the legacy grant for the same login is gone")

    let second = AppGrant(accessToken: "x-at", refreshToken: "x-rt", expiresAt: Date().addingTimeInterval(3600))
    try await provider.add(grant: second, profile: AccountProfile(email: "other@example.com", organization: "Org"))
    let again = AppGrant(accessToken: "y-at", refreshToken: "y-rt", expiresAt: Date().addingTimeInterval(3600))
    try await provider.add(grant: again, profile: AccountProfile(email: "me@example.com", organization: "Org"))

    #expect(store.accounts.count == 2)
    #expect(store.accounts.first { $0.key == "Me@Example.com" }?.grant.refreshToken == "y-rt")
}

@Test func unlabeledGrantsGetTheirEmail() async throws {
    let store = FakeAccounts([account("halp", order: 1)])
    let oauth = FakeOAuth(owners: ["halp-at": "me@example.com"])
    let provider = TokenProvider(store: store, refresher: oauth, profiles: oauth)

    await provider.identifyUnlabeled()
    #expect(store.accounts.first?.email == "me@example.com")
}

@Test func parsesATokenResponseWithItsSignInLifetime() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let rotated = try ClaudeOAuth.parseGrant(
        Data(#"{"access_token":"a","refresh_token":"r2","expires_in":28800,"refresh_token_expires_in":2592000}"#.utf8),
        previousRefreshToken: "r1", now: now
    )
    #expect(rotated == AppGrant(
        accessToken: "a", refreshToken: "r2",
        expiresAt: now.addingTimeInterval(28800), refreshExpiresAt: now.addingTimeInterval(2_592_000)
    ))

    let kept = try ClaudeOAuth.parseGrant(Data(#"{"access_token":"a","expires_in":60}"#.utf8), previousRefreshToken: "r1", now: now)
    #expect(kept.refreshToken == "r1")
    #expect(kept.refreshExpiresAt == nil)
}

@Test func readsTheLegacySingleGrantItemAsAnAccount() throws {
    let legacy = try JSONEncoder().encode(AppGrant(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0)))
    let decoded = try KeychainAccountStore.decode(legacy, key: "halp")
    #expect(decoded.key == "halp")
    #expect(decoded.email == nil)
    #expect(decoded.grant.refreshToken == "r")
}

@Test func findsEveryAccountItemInAKeychainDump() {
    let dump = """
    keychain: "/Users/test/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="me@example.com"
        "svce"<blob>="com.claudeusage.oauth"
    keychain: "/Users/test/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="halp"
        "svce"<blob>="Claude Code-credentials"
    keychain: "/Users/test/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="halp"
        "svce"<blob>="com.claudeusage.oauth"
    """
    #expect(KeychainAccountStore.accountNames(inDump: dump, service: "com.claudeusage.oauth") == ["me@example.com", "halp"])
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
