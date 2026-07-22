import XCTest

@MainActor
final class DailyUsageLimiterTests: XCTestCase {
    func testOnlySuccessfulFreeIdentificationsConsumeAllowance() {
        let suite = "DailyUsageLimiterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let limiter = DailyUsageLimiter(defaults: defaults, now: { date })

        XCTAssertEqual(limiter.remainingFreeUses, 2)
        XCTAssertTrue(limiter.canStartAnalysis(hasPremium: false))

        limiter.recordSuccessfulIdentification(hasPremium: false)
        XCTAssertEqual(limiter.remainingFreeUses, 1)
        limiter.recordSuccessfulIdentification(hasPremium: false)
        XCTAssertEqual(limiter.remainingFreeUses, 0)
        XCTAssertFalse(limiter.canStartAnalysis(hasPremium: false))
        XCTAssertTrue(limiter.canStartAnalysis(hasPremium: true))
    }

    func testPremiumSuccessDoesNotConsumeFreeAllowance() {
        let suite = "DailyUsageLimiterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let limiter = DailyUsageLimiter(defaults: defaults)

        limiter.recordSuccessfulIdentification(hasPremium: true)

        XCTAssertEqual(limiter.remainingFreeUses, 2)
    }
}
