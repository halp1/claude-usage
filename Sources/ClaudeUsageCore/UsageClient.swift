import Foundation

/// One rate-limit window as the menu bar renders it.
public struct LimitWindow: Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// Pay-as-you-go credits beyond the subscription's included usage.
///
/// The API reports these in minor units (cents for USD); amounts here are the
/// major-unit values the panel displays.
public struct CreditsInfo: Equatable, Sendable {
    public let used: Double
    /// `nil` when no monthly cap is configured, which the panel shows as "Unlimited".
    public let limit: Double?
    public let currency: String

    public init(used: Double, limit: Double?, currency: String = "USD") {
        self.used = used
        self.limit = limit
        self.currency = currency
    }

    public var percent: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(used / limit * 100, 100)
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let fiveHour: LimitWindow?
    public let weekly: LimitWindow?
    public let credits: CreditsInfo?
    public let fetchedAt: Date

    public init(fiveHour: LimitWindow?, weekly: LimitWindow?, credits: CreditsInfo?, fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.credits = credits
        self.fetchedAt = fetchedAt
    }
}

/// Fetches the usage summary the `/usage` command reads.
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "ClaudeUsage-MenuBar/1.0"

    private let tokens: TokenProvider
    private let session: URLSession

    public init(tokens: TokenProvider = TokenProvider(), session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    public func fetch() async throws -> UsageSnapshot {
        do {
            return try await fetch(forceRenewal: false)
        } catch UsageError.unauthorized {
            // The stored expiry can lag reality (revocation, clock skew, a token
            // Claude Code rotated). Ask the CLI to renew, then try once more.
            return try await fetch(forceRenewal: true)
        }
    }

    private func fetch(forceRenewal: Bool) async throws -> UsageSnapshot {
        let token = try await tokens.accessToken(forceRenewal: forceRenewal)

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.requestFailed(status: 0)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageError.requestFailed(status: http.statusCode)
        }
        return try Self.parse(data)
    }

    /// Hand-rolled because most fields in this payload are nullable and several
    /// sibling keys are experiments we deliberately ignore.
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformedResponse
        }

        func window(_ key: String) -> LimitWindow? {
            guard let object = root[key] as? [String: Any],
                  let utilization = object["utilization"] as? Double
            else { return nil }
            return LimitWindow(percent: utilization, resetsAt: date(object["resets_at"]))
        }

        var credits: CreditsInfo?
        if let extra = root["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            // Amounts arrive as integers in the currency's minor unit: 1111 with
            // decimal_places 2 is $11.11, matching `spend.used.amount_minor`.
            let scale = pow(10.0, (extra["decimal_places"] as? Double) ?? 2)
            credits = CreditsInfo(
                used: ((extra["used_credits"] as? Double) ?? 0) / scale,
                limit: (extra["monthly_limit"] as? Double).map { $0 / scale },
                currency: (extra["currency"] as? String) ?? "USD"
            )
        }

        let snapshot = UsageSnapshot(
            fiveHour: window("five_hour"),
            weekly: window("seven_day"),
            credits: credits,
            fetchedAt: now
        )
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else {
            throw UsageError.malformedResponse
        }
        return snapshot
    }

    /// Formatters are not `Sendable`, and this runs twice a minute, so building
    /// them per call is cheaper than the synchronization required to share them.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: string) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public enum UsageError: Error, LocalizedError {
    case unauthorized
    case requestFailed(status: Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Sign-in expired. Run `claude` and sign in again."
        case .requestFailed(let status) where status == 0:
            return "No response from the usage service."
        case .requestFailed(let status):
            return "Usage request failed (HTTP \(status))."
        case .malformedResponse:
            return "The usage service returned an unexpected response."
        }
    }
}
