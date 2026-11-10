import AppKit
import ClaudeUsageCore
import Observation
import ServiceManagement

/// Owns the polling loop and the last known good numbers for every account.
///
/// A failed fetch never clears an account's numbers: the panel keeps showing
/// its last real values and marks them stale, which is more useful than
/// blanking on a blip.
@MainActor
@Observable
final class UsageStore {
    /// One entry per signed-in account, in sign-in order.
    private(set) var accounts: [AccountState] = []
    /// Set when nothing could be listed at all, such as no accounts yet.
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    /// Recomputed on every tick so countdowns stay live without extra fetches.
    private(set) var now = Date()

    struct AccountState: Identifiable, Equatable {
        let account: Account
        /// Last successful numbers, kept across failed fetches.
        var snapshot: UsageSnapshot?
        /// Why the latest fetch failed, if it did.
        var error: String?
        /// After a 429, no request for this account before this time.
        var coolingUntil: Date?

        var id: String { account.key }
        var title: String { account.email ?? "Claude account" }
        var isStale: Bool { error != nil && snapshot != nil }
    }

    /// What the menu bar shows: every account's numbers pooled together.
    var combined: UsageSnapshot? {
        UsageSnapshot.combined(accounts.compactMap(\.snapshot))
    }

    var isStale: Bool { accounts.contains { $0.error != nil } && combined != nil }

    /// An error worth surfacing on the menu bar item.
    var headlineError: String? {
        lastError ?? accounts.first(where: { $0.error != nil }).map { "\($0.title): \($0.error ?? "")" }
    }

    let client: UsageClient
    private let interval: TimeInterval
    private var timer: Timer?

    init(client: UsageClient = UsageClient(), interval: TimeInterval = 120) {
        self.client = client
        self.interval = interval
    }

    func start() {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Keep firing while a menu tracks the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = interval * 0.1
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Timers do not fire while asleep; the on-screen value is old the
            // instant the lid opens.
            Task { @MainActor in self?.refresh() }
        }

        Task {
            // Label grants older versions saved without an email.
            await client.tokens.identifyUnlabeled()
            refresh()
        }
    }

    /// - Parameter trigger: `.panelOpened` fetches only accounts whose last
    ///   fetch failed. Accounts cooling down after a 429 are skipped either way.
    func refresh(_ trigger: FetchPolicy.Trigger = .scheduled) {
        now = Date()
        guard !isRefreshing else { return }

        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let skipping = Set(accounts.filter { state in
            !FetchPolicy.shouldFetch(
                FetchPolicy.State(hasSnapshot: state.snapshot != nil, failed: state.error != nil, coolingUntil: state.coolingUntil),
                trigger: trigger
            )
        }.map(\.id))
        // Nothing due. A panel opened right after a sign-in still lists the
        // new account, so only skip the round trip when the listing is current.
        if !accounts.isEmpty, skipping.count == accounts.count, trigger == .panelOpened, lastError == nil {
            return
        }
        isRefreshing = true

        Task {
            defer { isRefreshing = false }
            do {
                let results = try await client.fetchAll(skipping: skipping)
                accounts = results.map { result in
                    let old = previous[result.account.key]
                    if case .skipped = result.result {
                        return AccountState(account: result.account, snapshot: old?.snapshot, error: old?.error, coolingUntil: old?.coolingUntil)
                    }
                    return AccountState(
                        account: result.account,
                        snapshot: result.snapshot ?? old?.snapshot,
                        error: result.error,
                        coolingUntil: FetchPolicy.cooldown(after: result.result)
                    )
                }
                lastError = nil
            } catch {
                if case TokenError.signInRequired = error { accounts = [] }
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            now = Date()
        }
    }

    // MARK: - Accounts

    private(set) var isSigningIn = false
    private(set) var signInError: String?
    private var signInTask: Task<Void, Never>?

    /// Opens the browser to sign in. Signing in to an account already listed
    /// renews it; any other account is added.
    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        signInTask = Task {
            defer { isSigningIn = false; signInTask = nil }
            do {
                _ = try await SignIn(tokens: client.tokens).run { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                refresh()
            } catch is CancellationError {
                // Nothing to report.
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func remove(_ state: AccountState) {
        Task {
            do {
                try await client.tokens.remove(key: state.account.key)
                accounts.removeAll { $0.id == state.id }
                refresh()
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Returns: a message to surface when the request could not be honored.
    func setLaunchesAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }
}
