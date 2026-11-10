import Foundation
import Testing
@testable import ClaudeUsageCore

// MARK: - Usage payload

/// Trimmed from a real response, keeping the null-heavy experiment keys.
private let sampleUsageJSON = """
{
  "five_hour": {"utilization": 46.0, "resets_at": "2026-09-10T03:49:59.904075+00:00", "limit_dollars": null},
  "seven_day": {"utilization": 14.0, "resets_at": "2026-09-14T11:59:59.904102+00:00"},
  "seven_day_opus": null,
  "nimbus_quill": {"utilization": 0.0, "resets_at": null},
  "extra_usage": {"is_enabled": true, "monthly_limit": null, "used_credits": 1111.0, "currency": "USD", "decimal_places": 2}
}
"""

@Test func parsesTheUsagePayload() throws {
    let snapshot = try UsageClient.parse(Data(sampleUsageJSON.utf8))
    #expect(snapshot.fiveHour?.percent == 46)
    #expect(snapshot.weekly?.percent == 14)
    // Fractional seconds survive a Double round trip only to within epsilon.
    let expectedReset = try #require(ISO8601DateFormatter().date(from: "2026-09-10T03:49:59Z"))
    let actualReset = try #require(snapshot.fiveHour?.resetsAt)
    #expect(abs(actualReset.timeIntervalSince(expectedReset) - 0.904075) < 0.001)
    // 1111 minor units at decimal_places 2 is $11.11, not $1111.00.
    #expect(snapshot.credits?.used == 11.11)
    #expect(snapshot.credits?.currency == "USD")
    // No monthly cap configured, so there is no percentage to draw.
    #expect(snapshot.credits?.percent == nil)
}

@Test func parsesResetTimestampsWithoutFractionalSeconds() throws {
    let json = #"{"five_hour":{"utilization":5,"resets_at":"2026-09-10T03:49:59Z"}}"#
    let snapshot = try UsageClient.parse(Data(json.utf8))
    #expect(snapshot.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-09-10T03:49:59Z"))
}

@Test func treatsDisabledExtraUsageAsAbsent() throws {
    let json = #"{"five_hour":{"utilization":5},"extra_usage":{"is_enabled":false,"used_credits":10}}"#
    let snapshot = try UsageClient.parse(Data(json.utf8))
    #expect(snapshot.credits == nil)
}

@Test func computesCreditPercentAgainstAMonthlyCap() throws {
    let json = #"{"five_hour":{"utilization":5},"extra_usage":{"is_enabled":true,"used_credits":2500,"monthly_limit":10000,"decimal_places":2}}"#
    let snapshot = try UsageClient.parse(Data(json.utf8))
    #expect(snapshot.credits?.used == 25)
    #expect(snapshot.credits?.limit == 100)
    #expect(snapshot.credits?.percent == 25)
}

@Test func scalesCreditsForZeroDecimalCurrencies() throws {
    let json = #"{"five_hour":{"utilization":5},"extra_usage":{"is_enabled":true,"used_credits":1200,"currency":"JPY","decimal_places":0}}"#
    let snapshot = try UsageClient.parse(Data(json.utf8))
    #expect(snapshot.credits?.used == 1200)
    #expect(Format.money(1200, currency: "JPY") == "JPY 1200.00")
}

@Test func rejectsAPayloadWithNoLimitsAtAll() {
    #expect(throws: UsageError.self) {
        try UsageClient.parse(Data(#"{"seven_day_opus": null}"#.utf8))
    }
}

// MARK: - Formatting

@Test(arguments: [
    (0.0, Severity.normal), (74.9, .normal),
    (75.0, .warning), (89.9, .warning),
    (90.0, .critical), (100.0, .critical),
])
func severityThresholdsAreSeventyFiveAndNinety(percent: Double, expected: Severity) {
    #expect(Severity.forPercent(percent) == expected)
}

@Test func countdownUsesOneCoarseUnit() {
    let now = Date()
    func countdown(_ seconds: TimeInterval) -> String? {
        Format.countdown(to: now.addingTimeInterval(seconds), now: now)
    }
    #expect(countdown(30) == "now")
    #expect(countdown(-100) == "now")
    #expect(countdown(12 * 60) == "12m")
    #expect(countdown(59 * 60) == "59m")
    #expect(countdown(60 * 60) == "1h")
    // Truncated, never rounded up: 3h59m must not read as "4h".
    #expect(countdown(3 * 3600 + 59 * 60) == "3h")
    #expect(countdown(23 * 3600) == "23h")
    #expect(countdown(24 * 3600) == "1d")
    #expect(countdown(4 * 24 * 3600 + 22 * 3600) == "4d")
    #expect(Format.countdown(to: nil, now: now) == nil)
}

@Test func detailMatchesTheUsagePanelWording() {
    let now = Date()
    #expect(Format.detail(percent: 48, resetsAt: now.addingTimeInterval(3600), now: now) == "48% · resets 1h")
    #expect(Format.detail(percent: 14, resetsAt: now.addingTimeInterval(4 * 86400), now: now) == "14% · resets 4d")
    #expect(Format.detail(percent: 7, resetsAt: nil, now: now) == "7%")
}

@Test func percentAndDollarsRoundForDisplay() {
    #expect(Format.percent(46.4) == "46%")
    #expect(Format.percent(46.5) == "47%")
    #expect(Format.money(11.11) == "$11.11")
    #expect(Format.money(11.109) == "$11.11")
    #expect(Format.money(5, currency: "EUR") == "€5.00")
}

@Test func stalenessReadsInWholeUnits() {
    let now = Date()
    #expect(Format.staleness(since: now, now: now) == "updated just now")
    #expect(Format.staleness(since: now.addingTimeInterval(-4 * 60), now: now) == "updated 4m ago")
    #expect(Format.staleness(since: now.addingTimeInterval(-2 * 3600), now: now) == "updated 2h ago")
    #expect(Format.staleness(since: now.addingTimeInterval(-3 * 86400), now: now) == "updated 3d ago")
}

// MARK: - Combining accounts

@Test func combinesAccountsAsOnePool() throws {
    let soon = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 9_000)
    let a = UsageSnapshot(
        fiveHour: LimitWindow(percent: 50, resetsAt: later),
        weekly: LimitWindow(percent: 20, resetsAt: later),
        credits: CreditsInfo(used: 10, limit: 100),
        fetchedAt: later
    )
    let b = UsageSnapshot(
        fiveHour: LimitWindow(percent: 10, resetsAt: soon),
        weekly: nil,
        credits: CreditsInfo(used: 5, limit: nil),
        fetchedAt: soon
    )
    let combined = try #require(UsageSnapshot.combined([a, b]))

    #expect(combined.fiveHour == LimitWindow(percent: 30, resetsAt: soon), "average share, soonest reset")
    #expect(combined.weekly == LimitWindow(percent: 10, resetsAt: later), "a missing window is unused capacity")
    #expect(combined.credits == CreditsInfo(used: 15, limit: nil), "one uncapped account leaves the pool uncapped")
    #expect(combined.fetchedAt == soon, "staleness follows the oldest fetch")

    #expect(UsageSnapshot.combined([a]) == a)
    #expect(UsageSnapshot.combined([]) == nil)
}
