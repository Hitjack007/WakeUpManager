import Foundation

public enum ScheduleError: Error, Equatable {
    case invalidDateTime(String)
    case unknownTimeZone(String)
    case invalidRecurrence(String)
}

/// A local date and time with no zone, as written in a request: `yyyy-MM-dd'T'HH:mm[:ss]`.
struct LocalDateTime: Equatable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    init?(_ string: String) {
        let halves = string.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let dateParts = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = halves[1].split(separator: ":", omittingEmptySubsequences: false)
        let date = dateParts.compactMap { Int($0) }
        let time = timeParts.compactMap { Int($0) }
        guard date.count == 3, dateParts.count == 3,
              (2...3).contains(time.count), time.count == timeParts.count else { return nil }
        year = date[0]
        month = date[1]
        day = date[2]
        hour = time[0]
        minute = time[1]
        second = time.count == 3 ? time[2] : 0
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
    }
}

/// Turns a wall-clock `Schedule` into absolute start instants.
///
/// Every occurrence keeps the same local time, so a job at 07:00 stays at 07:00 when daylight saving
/// changes. A local time that doesn't exist (the spring-forward gap) runs at the next valid moment. A local
/// time that happens twice (the fall-back hour) uses the first one. Occurrences are always recomputed from
/// the rule, so call this again after the system time zone changes.
public struct ScheduleResolver: Sendable {
    /// The zone used when a schedule says `"system"`.
    public var systemTimeZone: TimeZone

    private static let maxDaysScanned = 366 * 30

    public init(systemTimeZone: TimeZone = .autoupdatingCurrent) {
        self.systemTimeZone = systemTimeZone
    }

    public func timeZone(for schedule: Schedule) throws -> TimeZone {
        if schedule.timeZone == Schedule.systemTimeZone { return systemTimeZone }
        guard let zone = TimeZone(identifier: schedule.timeZone) else {
            throw ScheduleError.unknownTimeZone(schedule.timeZone)
        }
        return zone
    }

    /// The first `limit` occurrences strictly after `after`, in order.
    public func occurrences(of schedule: Schedule, after: Date, limit: Int = 1) throws -> [Date] {
        guard limit > 0 else { return [] }
        guard let start = LocalDateTime(schedule.start) else {
            throw ScheduleError.invalidDateTime(schedule.start)
        }
        let zone = try timeZone(for: schedule)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        guard let anchorDay = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let startInstant = instant(on: anchorDay, time: start, calendar: calendar) else {
            throw ScheduleError.invalidDateTime(schedule.start)
        }

        guard let recurrence = schedule.recurrence else {
            return startInstant > after ? [startInstant] : []
        }
        guard recurrence.interval >= 1 else {
            throw ScheduleError.invalidRecurrence("interval must be at least 1")
        }

        var untilInstant: Date?
        if let until = recurrence.until {
            guard let local = LocalDateTime(until),
                  let day = calendar.date(from: DateComponents(year: local.year, month: local.month, day: local.day)),
                  let instant = instant(on: day, time: local, calendar: calendar) else {
                throw ScheduleError.invalidDateTime(until)
            }
            untilInstant = instant
        }

        let anchorWeekday = calendar.component(.weekday, from: anchorDay)
        let anchorMondayIndex = (anchorWeekday + 5) % 7          // Monday = 0 ... Sunday = 6
        let weekdays: Set<Int> = Set((recurrence.daysOfWeek ?? [Weekday(calendarValue: anchorWeekday)].compactMap { $0 })
            .map(\.calendarValue))
        guard recurrence.frequency == .daily || !weekdays.isEmpty else {
            throw ScheduleError.invalidRecurrence("weekly needs at least one day")
        }

        // Jump close to `after` instead of walking from the first day.
        var dayOffset = max(0, Int((after.timeIntervalSince(startInstant) / 86_400).rounded(.down)) - 2)
        let lastOffset = dayOffset + Self.maxDaysScanned
        var results: [Date] = []

        while results.count < limit, dayOffset <= lastOffset {
            defer { dayOffset += 1 }
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: anchorDay) else { break }

            switch recurrence.frequency {
            case .daily:
                guard dayOffset % recurrence.interval == 0 else { continue }
            case .weekly:
                let weekIndex = (dayOffset + anchorMondayIndex) / 7
                guard weekIndex % recurrence.interval == 0,
                      weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            }

            guard let occurrence = instant(on: day, time: start, calendar: calendar) else { continue }
            if let untilInstant, occurrence > untilInstant { break }
            if occurrence > after, occurrence >= startInstant { results.append(occurrence) }
        }
        return results
    }

    /// The absolute instant for `time` on the local day that starts at `day`.
    private func instant(on day: Date, time: LocalDateTime, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: day.addingTimeInterval(-1),
            matching: DateComponents(hour: time.hour, minute: time.minute, second: time.second),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
