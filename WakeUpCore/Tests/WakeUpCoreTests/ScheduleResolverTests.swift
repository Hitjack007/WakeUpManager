import Foundation
import Testing
@testable import WakeUpCore

/// Parses an ISO 8601 instant with an explicit offset, e.g. `2026-09-27T07:00:00+13:00`.
func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso) else { fatalError("bad test date \(iso)") }
    return date
}

private let auckland = TimeZone(identifier: "Pacific/Auckland")!
private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func resolver(_ zone: TimeZone = auckland) -> ScheduleResolver {
    ScheduleResolver(systemTimeZone: zone)
}

private func daily(_ start: String, zone: String = "system", interval: Int = 1, until: String? = nil) -> Schedule {
    Schedule(start: start, timeZone: zone, recurrence: Recurrence(frequency: .daily, interval: interval, until: until))
}

@Suite("Schedule resolver")
struct ScheduleResolverTests {
    // MARK: one-shot

    @Test func oneShotReturnsItsStartOnce() throws {
        let schedule = Schedule(start: "2026-11-12T01:13:00")
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-11T00:00:00+13:00"))
        #expect(result == [instant("2026-11-12T01:13:00+13:00")])
    }

    @Test func oneShotInThePastReturnsNothing() throws {
        let schedule = Schedule(start: "2026-11-12T01:13:00")
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-13T00:00:00+13:00"))
        #expect(result.isEmpty)
    }

    @Test func occurrenceEqualToAfterIsExcluded() throws {
        let schedule = daily("2026-11-09T07:00:00")
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-09T07:00:00+13:00"), limit: 1)
        #expect(result == [instant("2026-11-10T07:00:00+13:00")])
    }

    // MARK: daylight saving (Pacific/Auckland: spring forward Sun 27 Sep 2026 02:00, fall back Sun 5 Apr 2026 03:00)

    @Test func dailySevenAmStaysAtSevenAcrossSpringForward() throws {
        let result = try resolver().occurrences(
            of: daily("2026-09-25T07:00:00"), after: instant("2026-09-24T00:00:00+12:00"), limit: 4)
        #expect(result == [
            instant("2026-09-25T07:00:00+12:00"),
            instant("2026-09-26T07:00:00+12:00"),
            instant("2026-09-27T07:00:00+13:00"),   // the clocks went forward overnight: 23 hours later
            instant("2026-09-28T07:00:00+13:00"),
        ])
    }

    @Test func dailySevenAmStaysAtSevenAcrossFallBack() throws {
        let result = try resolver().occurrences(
            of: daily("2026-04-03T07:00:00"), after: instant("2026-04-02T00:00:00+13:00"), limit: 4)
        #expect(result == [
            instant("2026-04-03T07:00:00+13:00"),
            instant("2026-04-04T07:00:00+13:00"),
            instant("2026-04-05T07:00:00+12:00"),   // the clocks went back overnight: 25 hours later
            instant("2026-04-06T07:00:00+12:00"),
        ])
    }

    @Test func timeInTheSpringGapRunsAtTheNextValidMoment() throws {
        // 02:30 does not exist on 27 Sep 2026 in Auckland.
        let result = try resolver().occurrences(
            of: daily("2026-09-26T02:30:00"), after: instant("2026-09-25T00:00:00+12:00"), limit: 3)
        #expect(result == [
            instant("2026-09-26T02:30:00+12:00"),
            instant("2026-09-27T03:00:00+13:00"),
            instant("2026-09-28T02:30:00+13:00"),
        ])
    }

    @Test func timeRepeatedInTheFallBackHourUsesTheFirstOne() throws {
        // 02:30 happens twice on 5 Apr 2026 in Auckland (+13:00 then +12:00).
        let result = try resolver().occurrences(
            of: daily("2026-04-04T02:30:00"), after: instant("2026-04-03T00:00:00+13:00"), limit: 3)
        #expect(result == [
            instant("2026-04-04T02:30:00+13:00"),
            instant("2026-04-05T02:30:00+13:00"),
            instant("2026-04-06T02:30:00+12:00"),
        ])
    }

    // MARK: time zone

    @Test func systemZoneFollowsTheMacsCurrentZone() throws {
        let schedule = daily("2026-11-12T07:00:00", zone: "system")
        let after = instant("2026-11-11T00:00:00Z")
        let inAuckland = try resolver(auckland).occurrences(of: schedule, after: after)
        let inLosAngeles = try resolver(losAngeles).occurrences(of: schedule, after: after)
        #expect(inAuckland == [instant("2026-11-12T07:00:00+13:00")])
        #expect(inLosAngeles == [instant("2026-11-12T07:00:00-08:00")])
    }

    @Test func explicitZoneIgnoresTheSystemZone() throws {
        let schedule = daily("2026-11-12T07:00:00", zone: "Pacific/Auckland")
        let result = try resolver(losAngeles).occurrences(of: schedule, after: instant("2026-11-11T00:00:00Z"))
        #expect(result == [instant("2026-11-12T07:00:00+13:00")])
    }

    // MARK: recurrence rules

    @Test func dailyIntervalSkipsDays() throws {
        let result = try resolver().occurrences(
            of: daily("2026-11-09T07:00:00", interval: 2), after: instant("2026-11-08T00:00:00+13:00"), limit: 3)
        #expect(result == [
            instant("2026-11-09T07:00:00+13:00"),
            instant("2026-11-11T07:00:00+13:00"),
            instant("2026-11-13T07:00:00+13:00"),
        ])
    }

    @Test func weeklyOnSelectedDays() throws {
        // 9 Nov 2026 is a Monday.
        let schedule = Schedule(
            start: "2026-11-09T07:00:00",
            recurrence: Recurrence(frequency: .weekly, daysOfWeek: [.monday, .thursday]))
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-08T00:00:00+13:00"), limit: 4)
        #expect(result == [
            instant("2026-11-09T07:00:00+13:00"),
            instant("2026-11-12T07:00:00+13:00"),
            instant("2026-11-16T07:00:00+13:00"),
            instant("2026-11-19T07:00:00+13:00"),
        ])
    }

    @Test func weeklyDefaultsToTheStartWeekday() throws {
        let schedule = Schedule(start: "2026-11-12T07:00:00", recurrence: Recurrence(frequency: .weekly))
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-01T00:00:00+13:00"), limit: 2)
        #expect(result == [instant("2026-11-12T07:00:00+13:00"), instant("2026-11-19T07:00:00+13:00")])
    }

    @Test func weeklyIntervalSkipsWeeks() throws {
        let schedule = Schedule(
            start: "2026-11-09T07:00:00",
            recurrence: Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.monday]))
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-01T00:00:00+13:00"), limit: 3)
        #expect(result == [
            instant("2026-11-09T07:00:00+13:00"),
            instant("2026-11-23T07:00:00+13:00"),
            instant("2026-12-07T07:00:00+13:00"),
        ])
    }

    @Test func weeklyDoesNotRunBeforeItsStart() throws {
        // Starts on a Thursday, but Monday is selected: the first Monday after the start is the first run.
        let schedule = Schedule(
            start: "2026-11-12T07:00:00",
            recurrence: Recurrence(frequency: .weekly, daysOfWeek: [.monday]))
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-01T00:00:00+13:00"), limit: 1)
        #expect(result == [instant("2026-11-16T07:00:00+13:00")])
    }

    @Test func untilIsInclusiveAndStopsTheSeries() throws {
        let schedule = daily("2026-11-09T07:00:00", until: "2026-11-11T07:00:00")
        let result = try resolver().occurrences(of: schedule, after: instant("2026-11-01T00:00:00+13:00"), limit: 10)
        #expect(result == [
            instant("2026-11-09T07:00:00+13:00"),
            instant("2026-11-10T07:00:00+13:00"),
            instant("2026-11-11T07:00:00+13:00"),
        ])
    }

    @Test func farFutureLookupStillFindsTheNextOccurrence() throws {
        let result = try resolver().occurrences(
            of: daily("2026-11-09T07:00:00"), after: instant("2028-03-01T12:00:00+13:00"), limit: 2)
        #expect(result == [instant("2028-03-02T07:00:00+13:00"), instant("2028-03-03T07:00:00+13:00")])
    }

    // MARK: errors

    @Test func unknownZoneThrows() {
        let schedule = Schedule(start: "2026-11-12T07:00:00", timeZone: "Mars/Olympus")
        #expect(throws: ScheduleError.unknownTimeZone("Mars/Olympus")) {
            try resolver().occurrences(of: schedule, after: .now)
        }
    }

    @Test(arguments: ["tomorrow", "2026-11-12", "2026-13-12T07:00:00", "2026-11-12T25:00:00", "2026-11-12T07"])
    func invalidStartThrows(_ start: String) {
        #expect(throws: ScheduleError.invalidDateTime(start)) {
            try resolver().occurrences(of: Schedule(start: start), after: .now)
        }
    }

    @Test func zeroIntervalThrows() {
        let schedule = daily("2026-11-12T07:00:00", interval: 0)
        #expect(throws: ScheduleError.self) {
            try resolver().occurrences(of: schedule, after: .now)
        }
    }

    @Test func secondsAreOptionalInTheStart() throws {
        let result = try resolver().occurrences(
            of: Schedule(start: "2026-11-12T07:00"), after: instant("2026-11-11T00:00:00+13:00"))
        #expect(result == [instant("2026-11-12T07:00:00+13:00")])
    }
}
