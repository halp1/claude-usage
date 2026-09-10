import Foundation
import Testing
@testable import ClaudeUsageCore

// MARK: - Credentials

/// Mirrors the real keychain blob, including sibling keys we must not disturb.
private let sampleCredentialJSON = """
{
  "claudeAiOauth": {
    "accessToken": "access-1",
    "refreshToken": "refresh-1",
    "expiresAt": 1789017599542,
    "refreshTokenExpiresAt": 1790000000000,
    "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "team",
    "rateLimitTier": "default_raven"
  },
  "someOtherKey": {"nested": true}
}
"""

@Test func parsesNestedCredentials() throws {
    let credentials = try OAuthCredentials(json: Data(sampleCredentialJSON.utf8))
    #expect(credentials.accessToken == "access-1")
    #expect(credentials.refreshToken == "refresh-1")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1789017599.542))
}

@Test func writeBackPreservesEverythingWeDoNotOwn() throws {
    var credentials = try OAuthCredentials(json: Data(sampleCredentialJSON.utf8))
    credentials.accessToken = "access-2"
    credentials.refreshToken = "refresh-2"
    credentials.expiresAt = Date(timeIntervalSince1970: 1800000000)

    let round = try JSONSerialization.jsonObject(with: credentials.jsonData()) as! [String: Any]
    let oauth = round["claudeAiOauth"] as! [String: Any]

    #expect(oauth["accessToken"] as? String == "access-2")
    #expect(oauth["refreshToken"] as? String == "refresh-2")
    #expect(oauth["expiresAt"] as? Double == 1800000000000)
    // Fields Claude Code owns must survive untouched.
    #expect(oauth["subscriptionType"] as? String == "team")
    #expect(oauth["rateLimitTier"] as? String == "default_raven")
    #expect(oauth["refreshTokenExpiresAt"] as? Double == 1790000000000)
    #expect((oauth["scopes"] as? [String])?.count == 2)
    #expect((round["someOtherKey"] as? [String: Any])?["nested"] as? Bool == true)
}

@Test func acceptsFlatCredentialsWithoutTheOAuthWrapper() throws {
    let flat = #"{"accessToken":"a","refreshToken":"r","expiresAt":1789017599542}"#
    var credentials = try OAuthCredentials(json: Data(flat.utf8))
    credentials.accessToken = "b"
    let round = try JSONSerialization.jsonObject(with: credentials.jsonData()) as! [String: Any]
    #expect(round["accessToken"] as? String == "b")
    #expect(round["claudeAiOauth"] == nil)
}

@Test func rejectsBlobWithoutTokens() {
    #expect(throws: CredentialsError.self) {
        try OAuthCredentials(json: Data(#"{"claudeAiOauth":{"scopes":[]}}"#.utf8))
    }
}

@Test func refreshIsDueOnlyInsideTheLeeway() {
    let now = Date()
    func credentials(expiringIn seconds: TimeInterval) -> OAuthCredentials {
        OAuthCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(seconds))
    }
    #expect(credentials(expiringIn: 3600).needsRefresh(now: now) == false)
    #expect(credentials(expiringIn: 61).needsRefresh(now: now) == false)
    #expect(credentials(expiringIn: 30).needsRefresh(now: now) == true)
    #expect(credentials(expiringIn: -1).needsRefresh(now: now) == true)
}

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
