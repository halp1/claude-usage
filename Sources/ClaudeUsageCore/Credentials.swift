import Foundation

/// The parts of Claude Code's stored login this app is allowed to see.
///
/// Claude Code's keychain item also holds its refresh token. This type does not
/// read it, on purpose: refresh tokens are single-use, and rotating Claude
/// Code's once logged Claude Code out into a `/login` loop. With no refresh
/// token in memory, nothing in this app can renew Claude Code's grant, even by
/// mistake. The app renews only its own grant (`AppGrant`).
public struct OAuthCredentials: Sendable {
    public static let service = "Claude Code-credentials"
    /// Claude Code nests the tokens under this key.
    static let oauthKey = "claudeAiOauth"

    public let accessToken: String
    public let expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// True when the token is gone or close enough to expiry that a request
    /// started now could outlive it.
    public func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    public init(json data: Data) throws {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformed("credential blob is not a JSON object")
        }
        let fields = (envelope[Self.oauthKey] as? [String: Any]) ?? envelope

        guard let accessToken = fields["accessToken"] as? String, !accessToken.isEmpty else {
            throw CredentialsError.malformed("no accessToken in credential blob")
        }
        // Claude Code writes epoch milliseconds.
        guard let expiresAtMillis = fields["expiresAt"] as? Double else {
            throw CredentialsError.malformed("no expiresAt in credential blob")
        }
        self.accessToken = accessToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAtMillis / 1000)
    }
}

public enum CredentialsError: Error, LocalizedError {
    case notFound
    case malformed(String)
    /// `/usr/bin/security` exited non-zero. It reports only the low byte of the
    /// OSStatus, so the raw exit code is kept as-is.
    case securityTool(Int32)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials in the keychain. Sign in to Claude Usage instead."
        case .malformed(let detail):
            return "Could not read Claude Code credentials: \(detail)."
        case .securityTool(let code):
            return "Keychain read failed (security exited with \(code)). Is the login keychain locked?"
        }
    }
}

/// Reads Claude Code's credential item. Read-only on purpose; see `OAuthCredentials`.
public protocol CredentialStore: Sendable {
    func load() throws -> OAuthCredentials
}

/// Reads the item through `/usr/bin/security`; see `SecurityTool` for why that
/// avoids the recurring keychain password prompt.
public struct KeychainCredentialStore: CredentialStore {
    private let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    public func load() throws -> OAuthCredentials {
        let output: SecurityTool.Output
        do {
            output = try SecurityTool.run(["find-generic-password", "-s", OAuthCredentials.service, "-a", account, "-w"])
        } catch {
            throw CredentialsError.malformed("could not run \(SecurityTool.path): \(error.localizedDescription)")
        }
        switch output.status {
        case 0:
            guard !output.text.isEmpty else { throw CredentialsError.malformed("empty keychain item") }
            return try OAuthCredentials(json: Data(output.text.utf8))
        case SecurityTool.itemNotFoundExitCode:
            throw CredentialsError.notFound
        default:
            throw CredentialsError.securityTool(output.status)
        }
    }
}
