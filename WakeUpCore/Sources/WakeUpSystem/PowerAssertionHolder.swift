import Foundation
import IOKit.pwr_mgt
import WakeUpCore

/// Holds the Mac awake with the same three assertions `caffeinate -ims` uses, which the wake spike
/// showed keeps a Mac awake after a scheduled wake: no idle sleep, no disk idle, and (on AC power) no
/// system sleep.
///
/// Calling `hold` while already holding does nothing, and `release` while not holding does nothing.
public final class PowerAssertionHolder: AwakeHolder {
    public static let namePrefix = "WakeUp Manager"

    private var assertionIDs: [IOPMAssertionID] = []

    public init() {}

    deinit {
        release()
    }

    public var isHeld: Bool { !assertionIDs.isEmpty }

    public func hold(reason: String) {
        guard !isHeld else { return }
        let types: [CFString] = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            kIOPMAssertionTypePreventSystemSleep as CFString,
            "PreventDiskIdle" as CFString,   // the same type `caffeinate -m` uses
        ]
        for type in types {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "\(Self.namePrefix): \(reason)" as CFString, &id)
            if result == kIOReturnSuccess { assertionIDs.append(id) }
        }
    }

    public func release() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs = []
    }
}
