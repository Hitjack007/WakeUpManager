import Foundation
import Testing
@testable import WakeUpCore

private let sample = """
2026-11-11 13:48:53 +1300 Wake Requests       \t[process=dasd request=SleepService deltaSecs=1047 wakeAt=2026-11-11 14:06:20 info="x"]
2026-11-11 13:52:30 +1300 Wake                \tWake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/HID Activity Using AC (Charge:0%) 261 secs
2026-11-11 13:56:54 +1300 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_RX_IP_PACKET ARPT/ Using AC (Charge:0%) 10 secs
2026-11-11 13:57:04 +1300 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:0%)
2026-11-11 14:30:00 +1300 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to EC.LidOpen/ Using AC
2026-11-11 15:00:00 +1300 Sleep               \tEntering Sleep state due to 'Software Sleep pid=86592'
"""

@Suite("Reading the wake history")
struct WakeLogParserTests {
    private func date(_ text: String) -> Date { instant(text) }

    @Test func readsOnlyWakeLinesNewestFirst() {
        let events = WakeLogParser.parse(sample)
        #expect(events.count == 4)
        #expect(events.first?.time == date("2026-11-11T14:30:00+13:00"))
        #expect(events.last?.time == date("2026-11-11T13:52:30+13:00"))
    }

    @Test func aTimerWakeAtABookedTimeIsTheSchedulers() {
        let events = WakeLogParser.parse(sample, scheduledWakes: [date("2026-11-11T13:52:30+13:00")])
        let timer = events.first { $0.time == date("2026-11-11T13:52:30+13:00") }
        #expect(timer?.source == .scheduler)
        #expect(timer?.kind == "Wake")
    }

    @Test func aTimerWakeNobodyBookedIsNotTheSchedulers() {
        let events = WakeLogParser.parse(sample)
        let timer = events.first { $0.time == date("2026-11-11T13:52:30+13:00") }
        #expect(timer?.source == .apple)
    }

    @Test func networkAndUserWakesAreTold() {
        let events = WakeLogParser.parse(sample)
        #expect(events.first { $0.reason.contains("wifibt") }?.source == .network)
        #expect(events.first { $0.reason.contains("UserActivity") }?.source == .user)
        #expect(events.first { $0.reason.contains("LidOpen") }?.source == .user)
    }

    @Test func theReasonDropsTheTrailingPowerDetails() {
        let events = WakeLogParser.parse(sample)
        let network = events.first { $0.reason.contains("wifibt") }
        #expect(network?.reason.contains("Using AC") == false)
        #expect(network?.reason.hasPrefix("smc.sysState.Wake") == true)
    }

    @Test func keepsOnlyTheNewestWithinTheLimit() {
        #expect(WakeLogParser.parse(sample, limit: 2).count == 2)
    }
}
