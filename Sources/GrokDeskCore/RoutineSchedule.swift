import Foundation

public enum RoutineScheduleError: LocalizedError, Equatable {
    case invalidFieldCount
    case invalidField(String)
    case invalidTimeZone(String)
    case noOccurrence

    public var errorDescription: String? {
        switch self {
        case .invalidFieldCount: "A routine schedule must contain five fields: minute hour day-of-month month day-of-week."
        case .invalidField(let field): "Invalid cron field: \(field)"
        case .invalidTimeZone(let identifier): "Unknown time zone: \(identifier)"
        case .noOccurrence: "This schedule has no occurrence in the supported calendar horizon."
        }
    }
}

public struct RoutineSchedulePreset: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let cron: String

    public init(title: String, cron: String) {
        self.id = cron
        self.title = title
        self.cron = cron
    }
}

/// A small, numeric five-field cron dialect. Scheduling uses local wall-clock fields
/// in the selected IANA zone; a fall-back repeated minute therefore has two UTC dates.
public struct RoutineSchedule: Equatable, Sendable {
    private let minute: CronField
    private let hour: CronField
    private let dayOfMonth: CronField
    private let month: CronField
    private let dayOfWeek: CronField
    public let expression: String

    public static let presets: [RoutineSchedulePreset] = [
        .init(title: "Every minute", cron: "* * * * *"),
        .init(title: "Every hour", cron: "0 * * * *"),
        .init(title: "Daily at 9:00 AM", cron: "0 9 * * *"),
        .init(title: "Weekdays at 9:00 AM", cron: "0 9 * * 1-5"),
        .init(title: "Weekly on Monday at 9:00 AM", cron: "0 9 * * 1"),
    ]

    private static let searchHorizonMinutes = 8 * 366 * 24 * 60

    public init(cron: String) throws {
        let fields = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw RoutineScheduleError.invalidFieldCount }
        minute = try CronField(fields[0], range: 0...59, sundayAliases: false)
        hour = try CronField(fields[1], range: 0...23, sundayAliases: false)
        dayOfMonth = try CronField(fields[2], range: 1...31, sundayAliases: false)
        month = try CronField(fields[3], range: 1...12, sundayAliases: false)
        dayOfWeek = try CronField(fields[4], range: 0...7, sundayAliases: true)
        expression = fields.joined(separator: " ")
    }

    public func next(after date: Date, timeZoneID: String) throws -> Date? {
        let zone = try timeZone(timeZoneID)
        guard canMatchAnyCalendarDay else { return nil }
        let minuteFloor = floor(date.timeIntervalSince1970 / 60) * 60
        return try find(startingAt: minuteFloor + 60, step: 60, count: Self.searchHorizonMinutes, zone: zone)
    }

    public func previous(onOrBefore date: Date, timeZoneID: String) throws -> Date? {
        let zone = try timeZone(timeZoneID)
        guard canMatchAnyCalendarDay else { return nil }
        let minuteFloor = floor(date.timeIntervalSince1970 / 60) * 60
        return try find(startingAt: minuteFloor, step: -60, count: Self.searchHorizonMinutes, zone: zone)
    }

    public func nextRun(after date: Date, timeZoneID: String) throws -> Date {
        guard let date = try next(after: date, timeZoneID: timeZoneID) else { throw RoutineScheduleError.noOccurrence }
        return date
    }

    private func timeZone(_ identifier: String) throws -> TimeZone {
        guard let zone = TimeZone(identifier: identifier) else { throw RoutineScheduleError.invalidTimeZone(identifier) }
        return zone
    }

    private var canMatchAnyCalendarDay: Bool {
        // With a restricted weekday field cron's traditional DOM/DOW OR rule guarantees
        // a match. Otherwise a restricted DOM value must fit at least one selected month.
        if dayOfMonth.isWildcard || !dayOfWeek.isWildcard { return true }
        for monthNumber in month.values {
            let longestDay: Int
            switch monthNumber {
            case 2: longestDay = 29
            case 4, 6, 9, 11: longestDay = 30
            default: longestDay = 31
            }
            if dayOfMonth.values.contains(where: { $0 <= longestDay }) { return true }
        }
        return false
    }

    private func find(startingAt timestamp: Double, step: Double, count: Int, zone: TimeZone) throws -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var value = timestamp
        for _ in 0..<count {
            let date = Date(timeIntervalSince1970: value)
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
            guard let minuteValue = components.minute,
                  let hourValue = components.hour,
                  let dayValue = components.day,
                  let monthValue = components.month,
                  let weekdayValue = components.weekday
            else {
                value += step
                continue
            }
            let cronWeekday = weekdayValue - 1 // Foundation Sunday=1; cron Sunday=0.
            if minute.values.contains(minuteValue),
               hour.values.contains(hourValue),
               month.values.contains(monthValue),
               dayMatches(day: dayValue, weekday: cronWeekday) {
                return date
            }
            value += step
        }
        return nil
    }

    private func dayMatches(day: Int, weekday: Int) -> Bool {
        let monthDayMatches = dayOfMonth.values.contains(day)
        let weekDayMatches = dayOfWeek.values.contains(weekday)
        if dayOfMonth.isWildcard || dayOfWeek.isWildcard { return monthDayMatches && weekDayMatches }
        return monthDayMatches || weekDayMatches
    }
}

private struct CronField: Equatable, Sendable {
    let values: Set<Int>
    let isWildcard: Bool

    init(_ expression: String, range: ClosedRange<Int>, sundayAliases: Bool) throws {
        guard !expression.isEmpty else { throw RoutineScheduleError.invalidField(expression) }
        var parsed: Set<Int> = []
        for piece in expression.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !piece.isEmpty else { throw RoutineScheduleError.invalidField(expression) }
            let stepParts = piece.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(stepParts.count) else { throw RoutineScheduleError.invalidField(expression) }
            let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
            guard let step, step > 0 else { throw RoutineScheduleError.invalidField(expression) }
            let base = String(stepParts[0])
            let lower: Int
            let upper: Int
            if base == "*" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if base.contains("-") {
                let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end else {
                    throw RoutineScheduleError.invalidField(expression)
                }
                lower = start
                upper = end
            } else if let single = Int(base) {
                lower = single
                upper = stepParts.count == 2 ? range.upperBound : single
            } else {
                throw RoutineScheduleError.invalidField(expression)
            }
            guard range.contains(lower), range.contains(upper) else { throw RoutineScheduleError.invalidField(expression) }
            var value = lower
            while value <= upper {
                parsed.insert(sundayAliases && value == 7 ? 0 : value)
                let (next, overflow) = value.addingReportingOverflow(step)
                if overflow { break }
                value = next
            }
        }
        guard !parsed.isEmpty else { throw RoutineScheduleError.invalidField(expression) }
        values = parsed
        isWildcard = expression == "*"
    }
}
