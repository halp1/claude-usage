import Foundation
import Security

/// The OAuth credential blob Claude Code stores in the login keychain.
///
/// The keychain item holds a JSON document we do not fully own, so the raw
/// dictionaries are retained verbatim and only the three token fields are
/// rewritten. Anything Claude Code adds survives a round trip untouched.
public struct OAuthCredentials: Sendable {
    public static let service = "Claude Code-credentials"
    /// Claude Code nests the tokens under this key.
    static let oauthKey = "claudeAiOauth"

    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// The document exactly as it was read, kept as bytes so this type stays
    /// `Sendable`; it is re-parsed only when writing back.
    private var envelopeData: Data?
    /// Whether the tokens were nested under `claudeAiOauth` or stored flat.
    private var isNested: Bool

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.envelopeData = nil
        self.isNested = true
    }

    public var isExpired: Bool { expiresAt <= Date() }

    /// True when the token is gone or close enough to expiry that a request
    /// started now could outlive it.
    public func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    // MARK: - JSON

    public init(json data: Data) throws {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformed("credential blob is not a JSON object")
        }
        let nested = envelope[Self.oauthKey] as? [String: Any]
        let fields = nested ?? envelope

        guard let accessToken = fields["accessToken"] as? String, !accessToken.isEmpty else {
            throw CredentialsError.malformed("no accessToken in credential blob")
        }
        guard let refreshToken = fields["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw CredentialsError.malformed("no refreshToken in credential blob")
        }
        // Claude Code writes epoch milliseconds.
        guard let expiresAtMillis = fields["expiresAt"] as? Double else {
            throw CredentialsError.malformed("no expiresAt in credential blob")
        }

        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date(timeIntervalSince1970: expiresAtMillis / 1000)
        self.envelopeData = data
        self.isNested = nested != nil
    }

    /// Re-serializes the original document with only the token fields replaced.
    public func jsonData() throws -> Data {
        var envelope = envelopeData
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var fields = (isNested ? envelope[Self.oauthKey] as? [String: Any] : envelope) ?? [:]

        fields["accessToken"] = accessToken
        fields["refreshToken"] = refreshToken
        fields["expiresAt"] = (expiresAt.timeIntervalSince1970 * 1000).rounded()

        if isNested {
            envelope[Self.oauthKey] = fields
        } else {
            envelope = fields
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
}

public enum CredentialsError: Error, LocalizedError {
    case notFound
    case malformed(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials in the keychain. Run `claude` and sign in."
        case .malformed(let detail):
            return "Could not read Claude Code credentials: \(detail)."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Reads the credential item. Protocol-backed so tests can exercise token
/// logic without touching the real keychain. This store is read-only on
/// purpose: writing back rotates Claude Code's OAuth grant and logs it out.
public protocol CredentialStore: Sendable {
    func load() throws -> OAuthCredentials
}

public struct KeychainCredentialStore: CredentialStore {
    private let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthCredentials.service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> OAuthCredentials {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialsError.malformed("empty keychain item") }
            return try OAuthCredentials(json: data)
        case errSecItemNotFound:
            throw CredentialsError.notFound
        default:
            throw CredentialsError.keychain(status)
        }
    }
}
