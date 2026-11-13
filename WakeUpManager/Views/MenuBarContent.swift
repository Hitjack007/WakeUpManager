//
//  MenuBarContent.swift
//  WakeUpManager
//

import SwiftUI

struct MenuBarContent: View {
    @Environment(SchedulerStore.self) private var store
    @Environment(SoftwareUpdater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open WakeUp Manager") { showWindow() }
        Divider()
        if let job = store.nextWakeJob, let wake = job.plannedWake {
            Text("Next wake: \(Text(wake, format: .dateTime.weekday(.abbreviated).hour().minute()))")
            Text(job.name)
        } else {
            Text("Nothing scheduled")
        }
        if store.isHoldingAwake {
            if let running = store.runningJob {
                Text("Holding awake: \(running.name)")
            } else {
                Text("Holding the Mac awake")
            }
        }
        Divider()
        if store.openAlertCount > 0 {
            Text("\(store.openAlertCount) alerts need attention")
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        Button("Quit WakeUp Manager") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Brings the window forward, opening one if they have all been closed. Opening it also brings back the
    /// Dock icon when that is set to follow the window.
    private func showWindow() {
        if !AppAppearance.hasOpenWindow() { openWindow(id: "main") }
        AppAppearance.apply(keepWindowsInFront: true)
    }
}
