import CryptoKit
import Foundation
import Security

/// Renews this app's own grant. A protocol so tests can stand in for the network.
public protocol GrantRefreshing: Sendable {
    func refresh(_ grant: AppGrant) async throws -> AppGrant
}

public enum OAuthError: Error, LocalizedError {
    /// The server refused the grant: revoked, expired, or already rotated.
    case grantRejected
    case requestFailed(status: Int)
    case malformedResponse
    case callbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .grantRejected:
            return "Sign-in was rejected. Sign in again."
        case .requestFailed(let status):
            return "Sign-in request failed (HTTP \(status))."
        case .malformedResponse:
            return "The sign-in service returned an unexpected response."
        case .callbackFailed(let detail):
            return "Sign-in did not complete: \(detail)."
        }
    }
}

/// Claude's OAuth endpoints, using the public PKCE client Claude Code and DSH use.
///
/// Only ever handles this app's own grant (`AppGrant`). It must never be handed
/// Claude Code's credentials: refreshing those logs Claude Code out.
public struct ClaudeOAuth: GrantRefreshing {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// The exact scope set DSH requests with this client. The authorize page
    /// rejects narrower sets ("Invalid request format"), so match a known-good
    /// request rather than trimming it. The token stays in this app's keychain
    /// item and is only ever sent to `/api/oauth/usage`.
    static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func authorizationURL(challenge: String, state: String, redirectURI: String) -> URL {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> AppGrant {
        try await requestGrant([
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    public func refresh(_ grant: AppGrant) async throws -> AppGrant {
        try await requestGrant([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": grant.refreshToken,
        ], previousRefreshToken: grant.refreshToken)
    }

    private func requestGrant(_ body: [String: String], previousRefreshToken: String?) async throws -> AppGrant {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsageClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 || status == 403 {
            throw OAuthError.grantRejected
        }
        guard (200..<300).contains(status) else { throw OAuthError.requestFailed(status: status) }
        return try Self.parseGrant(data, previousRefreshToken: previousRefreshToken)
    }

    static func parseGrant(_ data: Data, previousRefreshToken: String?, now: Date = Date()) throws -> AppGrant {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty,
              let expiresIn = object["expires_in"] as? Double
        else { throw OAuthError.malformedResponse }
        // A refresh normally rotates the refresh token; keep the old one if not.
        guard let refresh = (object["refresh_token"] as? String) ?? previousRefreshToken, !refresh.isEmpty else {
            throw OAuthError.malformedResponse
        }
        return AppGrant(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn))
    }
}

/// RFC 7636 proof key helpers.
enum PKCE {
    static func randomURLSafe(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
