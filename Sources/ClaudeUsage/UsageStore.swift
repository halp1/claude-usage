import AppKit
import ClaudeUsageCore
import Observation
import ServiceManagement

/// Owns the polling loop and the last known good numbers.
///
/// A failed fetch never clears `snapshot`: the bar keeps showing the last real
/// values and marks them stale, which is more useful than blanking on a blip.
@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot: UsageSnapshot?
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    /// Recomputed on every tick so countdowns stay live without extra fetches.
    private(set) var now = Date()

    var isStale: Bool { lastError != nil && snapshot != nil }

    private let client: UsageClient
    private let interval: TimeInterval
    private var timer: Timer?

    init(client: UsageClient = UsageClient(), interval: TimeInterval = 60) {
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

        refresh()
    }

    func refresh() {
        now = Date()
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            defer { isRefreshing = false }
            do {
                snapshot = try await client.fetch()
                lastError = nil
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            now = Date()
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
