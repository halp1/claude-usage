import Foundation

/// One account's latest fetch: its numbers, or why they could not be read.
public struct AccountUsage: Equatable, Sendable, Identifiable {
    public enum Result: Equatable, Sendable {
        case success(UsageSnapshot)
        case failure(String)
    }

    public let account: Account
    public let result: Result

    public var id: String { account.key }

    public var snapshot: UsageSnapshot? {
        if case .success(let snapshot) = result { return snapshot }
        return nil
    }

    public var error: String? {
        if case .failure(let message) = result { return message }
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
