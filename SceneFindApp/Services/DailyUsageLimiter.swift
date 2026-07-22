import Foundation

@MainActor
final class DailyUsageLimiter: ObservableObject {
    static let freeSuccessLimit = 2

    @Published private(set) var successfulUsesToday = 0

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private static let dateKey = "usage.localDay.v1"
    private static let countKey = "usage.successCount.v1"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppGroupConfiguration.identifier) ?? .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        refreshForCurrentDay()
    }

    var remainingFreeUses: Int {
        max(0, Self.freeSuccessLimit - successfulUsesToday)
    }

    func canStartAnalysis(hasPremium: Bool) -> Bool {
        hasPremium || remainingFreeUses > 0
    }

    func recordSuccessfulIdentification(hasPremium: Bool) {
        guard !hasPremium else { return }
        refreshForCurrentDay()
        successfulUsesToday += 1
        defaults.set(successfulUsesToday, forKey: Self.countKey)
    }

    func refreshForCurrentDay() {
        let today = calendar.startOfDay(for: now())
        if defaults.object(forKey: Self.dateKey) as? Date != today {
            defaults.set(today, forKey: Self.dateKey)
            defaults.set(0, forKey: Self.countKey)
        }
        successfulUsesToday = defaults.integer(forKey: Self.countKey)
    }
}
