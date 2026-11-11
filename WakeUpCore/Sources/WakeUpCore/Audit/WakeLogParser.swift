import Foundation

/// One wake from `pmset -g log`: when the Mac woke, how, and who or what woke it.
public struct WakeLogEvent: Equatable, Sendable, Identifiable {
    public enum Source: String, Equatable, Sendable {
        /// A wake the scheduler booked.
        case scheduler
        /// A timer or maintenance wake from macOS or another program (an RTC alarm that isn't ours).
        case apple
        /// Network traffic (Wi-Fi, Bluetooth, Wake on LAN).
        case network
        /// Someone used the Mac: keyboard, mouse, lid, power button.
        case user
    }

    public var id: Date { time }
    public var time: Date
    /// `Wake` (the display and system came on) or `DarkWake` (a brief wake for maintenance or traffic).
    public var kind: String
    public var reason: String
    public var source: Source

    public init(time: Date, kind: String, reason: String, source: Source) {
        self.time = time
        self.kind = kind
        self.reason = reason
        self.source = source
    }
}

/// Reads the wake lines of `pmset -g log`:
///
///     2026-11-11 13:52:30 +1300 Wake   Wake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ rtc/HID Activity Using AC (Charge:0%) 261 secs
///     2026-11-11 13:56:54 +1300 DarkWake   DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake wifibt ARPT/ Using AC ...
public enum WakeLogParser {
    /// - Parameter scheduledWakes: the times the scheduler booked wakes for. A wake from a timer within
    ///   `tolerance` of one of them is the scheduler's own.
    public static func parse(
        _ output: String, scheduledWakes: [Date] = [], tolerance: TimeInterval = 90, limit: Int = 300
    ) -> [WakeLogEvent] {
        guard let line = try? Regex(#"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ([+-]\d{4}) (Wake|DarkWake)\s{2,}(.*)$"#) else {
            return []
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var events: [WakeLogEvent] = []
        for text in output.split(whereSeparator: \.isNewline) {
            guard let match = try? line.wholeMatch(in: text),
                  match.count == 5,
                  let stamp = match[1].substring, let zone = match[2].substring,
                  let kind = match[3].substring.map(String.init),
                  let detail = match[4].substring.map(String.init),
                  let time = formatter.date(from: "\(stamp) \(zone)") else { continue }
            let reason = reasonText(from: detail)
            events.append(WakeLogEvent(
                time: time, kind: kind, reason: reason,
                source: classify(reason: detail, at: time, scheduledWakes: scheduledWakes, tolerance: tolerance)))
        }
        return Array(events.suffix(limit).reversed())
    }

    /// The part after "due to", without the power source and duration pmset adds on the end.
    static func reasonText(from detail: String) -> String {
        var reason = detail
        if let range = detail.range(of: ": due to ") { reason = String(detail[range.upperBound...]) }
        if let range = reason.range(of: " Using ") { reason = String(reason[..<range.lowerBound]) }
        return reason.trimmingCharacters(in: .whitespaces)
    }

    static func classify(reason: String, at time: Date, scheduledWakes: [Date], tolerance: TimeInterval) -> WakeLogEvent.Source {
        let text = reason.lowercased()
        // A scheduled wake arrives as an RTC alarm, so only those can be the scheduler's own.
        if text.contains("rtc"), scheduledWakes.contains(where: { abs($0.timeIntervalSince(time)) <= tolerance }) { return .scheduler }
        if text.contains("wifibt") || text.contains("arpt") || text.contains("e_rx_ip_packet") || text.contains("en0")
            || text.contains("network") || text.contains("magic packet") { return .network }
        if text.contains("rtc") || text.contains("alarm") || text.contains("maintenance") { return .apple }
        if text.contains("useractivity") || text.contains("hid") || text.contains("lid") || text.contains("power button")
            || text.contains("keyboard") || text.contains("usb") { return .user }
        return .apple
    }
}
