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

struct UsagePanel: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin: Bool = false
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = store.snapshot {
                if let fiveHour = snapshot.fiveHour {
                    LimitRow(
                        title: "5-hour limit",
                        percent: fiveHour.percent,
                        detail: Format.detail(percent: fiveHour.percent, resetsAt: fiveHour.resetsAt, now: store.now)
                    )
                }
                if let weekly = snapshot.weekly {
                    LimitRow(
                        title: "Weekly · all models",
                        percent: weekly.percent,
                        detail: Format.detail(percent: weekly.percent, resetsAt: weekly.resetsAt, now: store.now)
                    )
                }
                if let credits = snapshot.credits {
                    creditsRow(credits)
                }
            } else if store.lastError != nil {
                Text(store.lastError ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            launchAtLogin = store.launchesAtLogin
            store.refresh()
        }
    }

    @ViewBuilder
    private func creditsRow(_ credits: CreditsInfo) -> some View {
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if store.isStale, let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
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
                Text(store.snapshot.map { Format.staleness(since: $0.fetchedAt, now: store.now) } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Refresh") { store.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(store.isRefreshing)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
