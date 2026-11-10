import Foundation

/// One account's latest fetch: its numbers, or why they could not be read.
public struct AccountUsage: Equatable, Sendable, Identifiable {
    public enum Result: Equatable, Sendable {
        case success(UsageSnapshot)
        /// `retryAfter` is set for a 429, when the server said when to retry.
        case failure(String, retryAfter: Date? = nil)
        /// Not fetched this time; the caller keeps what it had.
        case skipped
    }

    public let account: Account
    public let result: Result

    public var id: String { account.key }

    public var snapshot: UsageSnapshot? {
        if case .success(let snapshot) = result { return snapshot }
        return nil
    }

    public var error: String? {
        if case .failure(let message, _) = result { return message }
        return nil
    }

    public init(account: Account, result: Result) {
        self.account = account
        self.result = result
    }
}

extension UsageSnapshot {
    /// Usage across several accounts as one pool.
    ///
    /// Accounts on the same plan have the same limits, so the pool's share used
    /// is the average of each account's share. Each window resets when its
    /// soonest account resets, because that is when capacity next frees up.
    /// Credits add up, and keep a cap only when every account has one.
    ///
    /// - Returns: nil when no snapshot is given.
    public static func combined(_ snapshots: [UsageSnapshot]) -> UsageSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        if snapshots.count == 1 { return snapshots[0] }

        func pool(_ windows: [LimitWindow?]) -> LimitWindow? {
            let present = windows.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            // A missing window counts as unused capacity, not as absent.
            let percent = present.map(\.percent).reduce(0, +) / Double(windows.count)
            return LimitWindow(percent: percent, resetsAt: present.compactMap(\.resetsAt).min())
        }

        let credits = snapshots.compactMap(\.credits)
        var pooledCredits: CreditsInfo?
        if !credits.isEmpty, Set(credits.map(\.currency)).count == 1 {
            let limits = credits.compactMap(\.limit)
            pooledCredits = CreditsInfo(
                used: credits.map(\.used).reduce(0, +),
                limit: limits.count == credits.count ? limits.reduce(0, +) : nil,
                currency: credits[0].currency
            )
        }

        return UsageSnapshot(
            fiveHour: pool(snapshots.map(\.fiveHour)),
            weekly: pool(snapshots.map(\.weekly)),
            credits: pooledCredits,
            fetchedAt: snapshots.map(\.fetchedAt).min() ?? Date()
        )
    }
}

extension UsageClient {
    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Decides which accounts a refresh fetches, so the panel can be opened and
/// closed freely without tripping the usage endpoint's rate limit.
public enum FetchPolicy {
    public enum Trigger: Sendable {
        /// The timer or waking from sleep.
        case scheduled
        /// The panel opening: fetch only accounts whose last fetch failed.
        case panelOpened
        /// The Refresh button: fetch every account, even one cooling down.
        case manual
    }

    /// How long to leave an account alone after a 429 without `Retry-After`.
    public static let rateLimitBackoff: TimeInterval = 120

    public struct State: Sendable {
        public var hasSnapshot: Bool
        public var failed: Bool
        /// No request before this, whatever triggered the refresh.
        public var coolingUntil: Date?

        public init(hasSnapshot: Bool, failed: Bool, coolingUntil: Date?) {
            self.hasSnapshot = hasSnapshot
            self.failed = failed
            self.coolingUntil = coolingUntil
        }
    }

    /// - Returns: whether to fetch this account now.
    public static func shouldFetch(_ state: State?, trigger: Trigger, now: Date = Date()) -> Bool {
        guard let state else { return true }
        if trigger == .manual { return true }
        if let until = state.coolingUntil, until > now { return false }
        switch trigger {
        case .scheduled, .manual: return true
        case .panelOpened: return state.failed || !state.hasSnapshot
        }
    }

    /// When an account may be asked again after a failed fetch.
    public static func cooldown(after result: AccountUsage.Result, now: Date = Date()) -> Date? {
        guard case .failure(_, let retryAfter) = result else { return nil }
        guard let retryAfter else { return nil }
        return max(retryAfter, now.addingTimeInterval(10))
    }
}
