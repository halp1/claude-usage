import Foundation

/// Hands out an access token for `/api/oauth/usage`.
///
/// There are two sources, and they are kept strictly apart:
///
/// 1. **This app's own grant** (`AppGrant`), created by the in-app browser
///    sign-in. The app renews it on its own, indefinitely, the same way DSH
///    does. Claude Code never holds a copy, so renewing it cannot log Claude
///    Code out.
/// 2. **Claude Code's credential**, read-only, used only until the app has its
///    own grant. Its refresh token is never sent anywhere: refresh tokens are
///    single-use, and rotating Claude Code's once logged Claude Code out into a
///    `/login` loop. When its access token expires and the app has no grant of
///    its own, the user is asked to sign in.
public actor TokenProvider {
    private let claudeCode: CredentialStore
    private let grants: AppGrantStoring
    private let refresher: GrantRefreshing

    /// One renewal at a time. Refresh tokens are single-use, so two overlapping
    /// renewals would have the second spend an already-rotated token.
    private var renewal: Task<AppGrant, Error>?

    public init(
        claudeCode: CredentialStore = KeychainCredentialStore(),
        grants: AppGrantStoring = KeychainAppGrantStore(),
        refresher: GrantRefreshing = ClaudeOAuth()
    ) {
        self.claudeCode = claudeCode
        self.grants = grants
        self.refresher = refresher
    }

    /// - Parameter forceRenewal: renew the app's grant even if its expiry still
    ///   looks valid, used to recover from a 401 the timestamp missed.
    public func accessToken(forceRenewal: Bool = false) async throws -> String {
        if let grant = try grants.load() {
            if !forceRenewal, !grant.needsRefresh() {
                return grant.accessToken
            }
            do {
                return try await renew(grant).accessToken
            } catch TokenError.signInRequired {
                // Our grant is dead; Claude Code's token may still serve.
            }
        }

        // No grant of our own yet: borrow Claude Code's token while it is
        // valid. Read-only, and never renewed from here.
        let borrowed = try claudeCode.load()
        if !forceRenewal, !borrowed.needsRefresh() {
            return borrowed.accessToken
        }
        throw TokenError.signInRequired
    }

    /// Whether the app has its own grant, i.e. keeps working without Claude Code.
    public func hasOwnGrant() -> Bool {
        (try? grants.load()) != nil
    }

    /// Forgets the app's own grant. Claude Code's credential is untouched.
    public func signOut() throws {
        try grants.clear()
    }

    private func renew(_ grant: AppGrant) async throws -> AppGrant {
        if let renewal {
            return try await renewal.value
        }
        let task = Task { [grants, refresher] () throws -> AppGrant in
            do {
                let renewed = try await refresher.refresh(grant)
                try grants.save(renewed)
                return renewed
            } catch OAuthError.grantRejected {
                // Another process (say, `--probe`) may have rotated the grant
                // first. If the stored grant changed, it is the live one.
                if let current = try grants.load(), current.refreshToken != grant.refreshToken {
                    return current
                }
                throw TokenError.signInRequired
            }
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }
}

public enum TokenError: Error, LocalizedError, Equatable {
    case signInRequired

    public var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in to keep usage updating on its own."
        }
    }
}
