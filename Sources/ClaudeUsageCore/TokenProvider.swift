import Foundation

/// Hands out the access token Claude Code stored, asking Claude Code to renew it
/// when it has gone stale.
///
/// This type reads the shared keychain item and never writes it. When the token
/// is expired it shells out to the Claude Code CLI, which owns the grant, and
/// then re-reads. See `CredentialRenewer` for why delegating is the only safe
/// way to renew.
public actor TokenProvider {
    private let store: CredentialStore
    private let renewer: CredentialRenewing

    public init(
        store: CredentialStore = KeychainCredentialStore(),
        renewer: CredentialRenewing = ClaudeCLIRenewer()
    ) {
        self.store = store
        self.renewer = renewer
    }

    /// - Parameter forceRenewal: ask the CLI to renew even if the stored expiry
    ///   still looks valid, used to recover from a 401 the timestamp missed.
    public func accessToken(forceRenewal: Bool = false) async throws -> String {
        let credentials = try store.load()
        if !forceRenewal, !credentials.needsRefresh() {
            return credentials.accessToken
        }

        await renewer.renew()

        // Re-read: if the CLI renewed, this is the fresh token.
        let renewed = try store.load()
        guard !renewed.needsRefresh() else {
            throw TokenError.expired
        }
        return renewed.accessToken
    }
}

public enum TokenError: Error, LocalizedError {
    case expired

    public var errorDescription: String? {
        switch self {
        case .expired:
            return "Sign-in expired. Open Claude Code to sign in again."
        }
    }
}
