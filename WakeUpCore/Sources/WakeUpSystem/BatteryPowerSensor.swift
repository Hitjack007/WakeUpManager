import Foundation
import IOKit.ps
import WakeUpCore

/// Reads the power source and battery level from IOKit. A Mac with no internal battery (an iMac, a
/// Mac Studio) always reports as plugged in with no battery level.
public struct BatteryPowerSensor: PowerSensor {
    public init() {}

    public func current() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .plugged }

        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []

        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            percent = min(100, max(0, current * 100 / maximum))
        }

        // A UPS counts as mains power; only the Mac's own battery is subject to the battery rules.
        let onBattery = providing == kIOPSBatteryPowerValue
        return PowerState(source: onBattery ? .battery : .ac, batteryPercent: percent)
    }
}
