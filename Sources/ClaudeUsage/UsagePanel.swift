import ClaudeUsageCore
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }
}

/// A titled row with its percentage and a capsule meter, mirroring `/usage`.
private struct LimitRow: View {
    let title: String
    let percent: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Meter(percent: percent)
        }
    }
}

private struct Meter: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(percent / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(Severity.forPercent(percent).color)
                    // Keep a sliver visible at 1% so the bar never reads as empty.
                    .frame(width: max(fraction * geometry.size.width, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.25), value: percent)
    }
}

/// The 5-hour, weekly, and credits rows for one snapshot.
private struct LimitsView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let fiveHour = snapshot.fiveHour {
                LimitRow(
                    title: "5-hour limit",
                    percent: fiveHour.percent,
                    detail: Format.detail(percent: fiveHour.percent, resetsAt: fiveHour.resetsAt, now: now)
                )
            }
            if let weekly = snapshot.weekly {
                LimitRow(
                    title: "Weekly · all models",
                    percent: weekly.percent,
                    detail: Format.detail(percent: weekly.percent, resetsAt: weekly.resetsAt, now: now)
                )
            }
            if let credits = snapshot.credits {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Usage credits · \(Format.money(credits.used, currency: credits.currency))")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 12)
                        Text(credits.percent.map { Format.percent($0) } ?? "Unlimited")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let percent = credits.percent {
                        Meter(percent: percent)
                    }
                }
            }
        }
    }
}

/// One account: its email, its own limits, and its own problems.
private struct AccountSection: View {
    let state: UsageStore.AccountState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let snapshot = state.snapshot {
                LimitsView(snapshot: snapshot, now: now)
                    .opacity(state.isStale ? 0.55 : 1)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsagePanel: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin: Bool = false
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.accounts.count > 1, let combined = store.combined {
                VStack(alignment: .leading, spacing: 10) {
                    Text("All accounts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    LimitsView(snapshot: combined, now: store.now)
                }
                Divider()
            }

            if store.accounts.isEmpty {
                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(store.accounts) { state in
                AccountSection(state: state, now: store.now)
                if state.id != store.accounts.last?.id {
                    Divider()
                }
            }

            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            // The status item already refreshed on open; a second call here
            // doubled every open's requests.
            launchAtLogin = store.launchesAtLogin
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 8) {
                if store.accounts.isEmpty || store.isSigningIn {
                    Button(store.isSigningIn ? "Waiting for browser…" : "Sign In…") { store.signIn() }
                        .font(.system(size: 12))
                        .disabled(store.isSigningIn)
                }
                if store.isSigningIn {
                    Button("Cancel") { store.cancelSignIn() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let signInError = store.signInError {
                Text(signInError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let launchError {
                Text(launchError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // An explicit binding rather than `onChange`: syncing this state in
            // `onAppear` would otherwise fire the handler and register a login
            // item the user never asked for.
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in
                    launchError = store.setLaunchesAtLogin(enabled)
                    // Reflect what the service reports, not what we asked for.
                    launchAtLogin = store.launchesAtLogin
                }
            ))
            .font(.system(size: 12))
            .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Text(store.combined.map { Format.staleness(since: $0.fetchedAt, now: store.now) } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Refresh") { store.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(store.isRefreshing)
            }
        }
    }
}
