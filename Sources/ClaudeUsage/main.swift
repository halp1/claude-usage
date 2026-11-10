import AppKit
import ClaudeUsageCore
import ServiceManagement

/// `--probe` exercises keychain → token → HTTP → decode from the terminal, so
/// the whole data path can be verified without a GUI in the way.
/// Carries the probe's outcome across the isolation boundary; the detached task
/// is the only writer and the main thread reads it only after `wait()` returns.
private final class ProbeOutcome: @unchecked Sendable {
    var error: Error?
}

if CommandLine.arguments.contains("--login-status") {
    // Diagnostic: report the real registration state from inside the bundle,
    // which is the only context where SMAppService answers meaningfully.
    print("launch at login: \(SMAppService.mainApp.status.rawValue) (1 = enabled, 3 = notFound/notRegistered)")
    exit(0)
}

/// Runs async work from top-level code and exits non-zero on failure.
/// Detached on purpose: top-level code is `@MainActor`, so a plain `Task`
/// would inherit main-actor isolation and deadlock against `wait()`.
func runToCompletion(_ label: String, _ body: @escaping @Sendable () async throws -> Void) -> Never {
    let outcome = ProbeOutcome()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        do { try await body() } catch { outcome.error = error }
    }
    done.wait()
    if let error = outcome.error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data("\(label) failed: \(message)\n".utf8))
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--sign-in") {
    // Same browser sign-in as the panel's button, for use from a terminal.
    runToCompletion("sign-in") {
        let account = try await SignIn(tokens: TokenProvider()).run { url in
            print("Opening the browser to sign in. If it does not open, visit:\n\(url)")
            NSWorkspace.shared.open(url)
        }
        print("signed in as \(account.email ?? account.key)")
    }
}

if CommandLine.arguments.contains("--probe") {
    // The whole data path (keychain, tokens, HTTP, decode) without the GUI.
    runToCompletion("probe") {
        let client = UsageClient()
        await client.tokens.identifyUnlabeled()
        let results = try await client.fetchAll()
        func show(_ label: String, _ window: LimitWindow?) {
            guard let window else { print("  \(label): (absent)"); return }
            print("  \(label): \(Format.detail(percent: window.percent, resetsAt: window.resetsAt))")
        }
        func show(_ snapshot: UsageSnapshot) {
            show("5-hour  ", snapshot.fiveHour)
            show("weekly  ", snapshot.weekly)
            if let credits = snapshot.credits {
                let cap = credits.percent.map { Format.percent($0) } ?? "unlimited"
                print("  credits : \(Format.money(credits.used, currency: credits.currency)) (\(cap))")
            }
        }
        for result in results {
            let org = result.account.organization.map { " (\($0))" } ?? ""
            print("\(result.account.email ?? result.account.key)\(org)")
            if let snapshot = result.snapshot { show(snapshot) }
            if let error = result.error { print("  error   : \(error)") }
            if let ends = result.account.grant.refreshExpiresAt {
                print("  sign-in : valid until \(ends.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        if results.count > 1, let combined = UsageSnapshot.combined(results.compactMap(\.snapshot)) {
            print("combined")
            show(combined)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(store: store)
        store.start()
    }
}

let app = NSApplication.shared
// Menu bar only: no Dock tile, no app switcher entry.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
