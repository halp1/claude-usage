import Foundation

/// Hands out access tokens for the app's signed-in accounts and keeps each
/// account's grant renewed.
///
/// Every grant comes from the app's own browser sign-in, so the app is the only
/// holder of each refresh token and can renew it freely. Claude Code is never
/// read or touched.
public actor TokenProvider {
    private let store: AccountStoring
    private let refresher: GrantRefreshing
    private let profiles: ProfileLooking

    /// One renewal per account at a time. Refresh tokens are single-use, so two
    /// overlapping renewals would have the second spend an already-rotated token.
    private var renewals: [String: Task<AppGrant, Error>] = [:]

    public init(
        store: AccountStoring = KeychainAccountStore(),
        refresher: GrantRefreshing = ClaudeOAuth(),
        profiles: ProfileLooking = ClaudeOAuth()
    ) {
        self.store = store
        self.refresher = refresher
        self.profiles = profiles
    }

    public func accounts() throws -> [Account] {
        try store.list()
    }

    /// - Parameter forceRenewal: renew even if the expiry still looks valid,
    ///   used to recover from a 401 the timestamp missed.
    public func accessToken(for key: String, forceRenewal: Bool = false) async throws -> String {
        guard let account = try store.list().first(where: { $0.key == key }) else {
            throw TokenError.signInRequired
        }
        if !forceRenewal, !account.grant.needsRefresh() {
            return account.grant.accessToken
        }
        return try await renew(account).accessToken
    }

    /// Stores a fresh sign-in. Signing in again to an account already listed
    /// replaces its grant, so the same account never appears twice.
    @discardableResult
    public func add(grant: AppGrant, profile: AccountProfile?) async throws -> Account {
        let existing = try store.list()
        if let profile, let match = existing.first(where: { $0.email?.lowercased() == profile.email.lowercased() }) {
            var updated = match
            updated.grant = grant
            updated.organization = profile.organization ?? match.organization
            try store.save(updated)
            return updated
        }
        let key = profile?.email ?? "account-\(UUID().uuidString.prefix(8).lowercased())"
        let account = Account(key: key, email: profile?.email, organization: profile?.organization, grant: grant)
        try store.save(account)
        // Older versions kept one unlabeled grant under the login user name.
        // A sign-in to that same login supersedes it.
        if let profile {
            for legacy in existing where legacy.email == nil {
                if let owner = try? await profiles.profile(accessToken: accessToken(for: legacy.key)),
                   owner.email.lowercased() == profile.email.lowercased() {
                    try store.remove(key: legacy.key)
                }
            }
        }
        return account
    }

    /// Labels accounts saved without an email (older versions). Best effort:
    /// an account that cannot be reached stays unlabeled until next time.
    public func identifyUnlabeled() async {
        for account in (try? store.list()) ?? [] where account.email == nil {
            guard let token = try? await accessToken(for: account.key),
                  let profile = try? await profiles.profile(accessToken: token),
                  var current = try? store.list().first(where: { $0.key == account.key })
            else { continue }
            current.email = profile.email
            current.organization = profile.organization
            try? store.save(current)
        }
    }

    public func remove(key: String) throws {
        try store.remove(key: key)
    }

    private func renew(_ account: Account) async throws -> AppGrant {
        if let pending = renewals[account.key] {
            return try await pending.value
        }
        let key = account.key
        let task = Task { [store, refresher] () throws -> AppGrant in
            if account.grant.signInExpired() { throw TokenError.signInExpired(email: account.email) }
            do {
                let renewed = try await refresher.refresh(account.grant)
                var updated = account
                // Older responses omit the refresh lifetime; keep the known one.
                updated.grant = AppGrant(
                    accessToken: renewed.accessToken,
                    refreshToken: renewed.refreshToken,
                    expiresAt: renewed.expiresAt,
                    refreshExpiresAt: renewed.refreshExpiresAt ?? account.grant.refreshExpiresAt
                )
                try store.save(updated)
                return updated.grant
            } catch OAuthError.grantRejected {
                // Another process (say, `--probe`) may have rotated the grant
                // first. If the stored grant changed, it is the live one.
                if let current = try store.list().first(where: { $0.key == key }),
                   current.grant.refreshToken != account.grant.refreshToken {
                    return current.grant
                }
                throw TokenError.signInExpired(email: account.email)
            }
        }
        renewals[key] = task
        defer { renewals[key] = nil }
        return try await task.value
    }
}

public enum TokenError: Error, LocalizedError, Equatable {
    case signInRequired
    case signInExpired(email: String?)

    public var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in to see usage."
        case .signInExpired(let email):
            return "Sign-in for \(email ?? "this account") expired. Sign in again."
        }
    }
}
