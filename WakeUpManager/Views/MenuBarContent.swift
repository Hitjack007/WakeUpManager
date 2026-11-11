//
//  MenuBarContent.swift
//  WakeUpManager
//

import SwiftUI

struct MenuBarContent: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if let job = store.nextWakeJob, let wake = job.plannedWake {
            Text("Next wake: \(Text(wake, format: .dateTime.weekday(.abbreviated).hour().minute()))")
            Text(job.name)
        } else {
            Text("Nothing scheduled")
        }
        if let running = store.runningJob {
            Text("Holding awake: \(running.name)")
        }
        Divider()
        if store.openAlertCount > 0 {
            Text("\(store.openAlertCount) alerts need attention")
        }
        Button("Quit WakeUp Manager") {
            NSApplication.shared.terminate(nil)
        }
    }
}
