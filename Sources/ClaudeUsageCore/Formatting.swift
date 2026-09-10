import Foundation

/// How close a window is to its cap. Drives bar and menu bar color.
public enum Severity: Sendable {
    case normal
    case warning
    case critical

    public static func forPercent(_ percent: Double) -> Severity {
        switch percent {
        case 90...: return .critical
        case 75...: return .warning
        default: return .normal
        }
    }
}

public enum Format {
    /// Whole percent, matching how `/usage` reports it.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Coarse single-unit countdown: "4d", "3h", "12m", "now".
    ///
    /// Truncated rather than rounded so it never claims more time than remains.
    public static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Right-hand detail line: "48% · resets 1h", or just "48%" once expired.
    public static func detail(percent value: Double, resetsAt: Date?, now: Date = Date()) -> String {
        guard let countdown = countdown(to: resetsAt, now: now) else { return percent(value) }
        return "\(percent(value)) · resets \(countdown)"
    }

    /// Money as the panel shows it: "$11.11", or "EUR 11.11" for currencies
    /// without a symbol we recognize.
    public static func money(_ value: Double, currency: String = "USD") -> String {
        let amount = String(format: "%.2f", value)
        switch currency.uppercased() {
        case "USD": return "$\(amount)"
        case "EUR": return "€\(amount)"
        case "GBP": return "£\(amount)"
        default: return "\(currency.uppercased()) \(amount)"
        }
    }

    /// "updated 4m ago", shown when a fetch has failed and numbers are stale.
    public static func staleness(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "updated \(hours)h ago" }
        return "updated \(hours / 24)d ago"
    }
}
