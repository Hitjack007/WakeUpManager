import Foundation

/// A power event booked with macOS, as listed by `pmset -g sched`.
public struct ScheduledPowerEvent: Codable, Equatable, Hashable, Sendable {
    /// `wake`, `poweron`, `wakepoweron`, `sleep`, `shutdown`.
    public var kind: String
    public var date: Date
    /// The tag the booker gave it. This is the only record of who booked an event.
    public var owner: String

    public init(kind: String, date: Date, owner: String) {
        self.kind = kind
        self.date = date
        self.owner = owner
    }
}

/// Reads the pending power events. The real one runs `pmset -g sched`, which needs no privileges.
public protocol ScheduleReading {
    func scheduledEvents() throws -> [ScheduledPowerEvent]
}

/// Cancels a booked power event. Cancelling needs the exact kind, time and owner, and root.
public protocol PowerEventCancelling {
    func cancelEvent(kind: String, at date: Date, owner: String) throws
}

public enum WakeOwnerClass: Equatable, Sendable {
    /// Booked by the scheduler itself.
    case ours
    /// Booked by macOS (`com.apple.` owners). Never touched.
    case apple
    /// Booked by something the user has said may book its own wakes.
    case allowedByUser
    /// Booked by anything else.
    case foreign
}

/// Decides whose a booked event is, from its owner tag.
///
/// The `com.apple.` prefix is only a string any process with root could use, so this is a way of keeping
/// the scheduler from cancelling macOS's own wakes by mistake, not a security boundary.
public struct WakeOwnerPolicy: Equatable, Sendable {
    public var ourOwners: Set<String>
    public var applePrefixes: [String]
    public var allowedOwners: Set<String>

    public init(ourOwners: Set<String>, applePrefixes: [String] = ["com.apple."], allowedOwners: Set<String> = []) {
        self.ourOwners = ourOwners
        self.applePrefixes = applePrefixes
        self.allowedOwners = allowedOwners
    }

    public func classify(owner: String) -> WakeOwnerClass {
        if ourOwners.contains(owner) { return .ours }
        if applePrefixes.contains(where: { owner.hasPrefix($0) }) { return .apple }
        if allowedOwners.contains(owner) { return .allowedByUser }
        return .foreign
    }
}

/// Parses the output of `pmset -g sched`:
///
///     Scheduled power events:
///      [0]  wake at 11/11/2026 08:51:18 by 'com.apple.alarm.user-invisible-com.apple.calaccessd...'
public enum PmsetScheduleParser {
    public static func parse(_ output: String, timeZone: TimeZone = .current) -> [ScheduledPowerEvent] {
        guard let line = try? Regex(#"^\s*\[\d+\]\s+(\S+)\s+at\s+(\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2})\s+by\s+'(.*)'\s*$"#) else {
            return []
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"

        var events: [ScheduledPowerEvent] = []
        for text in output.split(whereSeparator: \.isNewline) {
            guard let match = try? line.wholeMatch(in: text),
                  match.count == 4,
                  let kind = match[1].substring.map(String.init),
                  let when = match[2].substring.map(String.init),
                  let owner = match[3].substring.map(String.init),
                  let date = formatter.date(from: when) else { continue }
            events.append(ScheduledPowerEvent(kind: kind, date: date, owner: owner))
        }
        return events
    }
}
