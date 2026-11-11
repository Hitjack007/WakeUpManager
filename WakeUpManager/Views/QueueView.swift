//
//  QueueView.swift
//  WakeUpManager
//

import SwiftUI

struct QueueView: View {
    @Environment(SchedulerStore.self) private var store
    @State private var selectedID: String? = "nhl-game-recording"

    var body: some View {
        Table(store.jobs, selection: $selectedID) {
            TableColumn("Job") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).fontWeight(.medium)
                    Text(job.clientName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 200)
            TableColumn("Next run") { job in
                if let next = job.nextRun {
                    WhenText(date: next)
                } else {
                    Text("Now").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Repeats") { job in
                Text(job.repeatText)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Intensity") { job in
                IntensityBadge(level: job.intensity)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Estimate") { job in
                Text("\(job.estimatedMinutes) min")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Status") { job in
                StateBadge(state: job.state)
            }
            .width(min: 150, ideal: 170)
        }
        .navigationTitle("Queue")
        .inspector(isPresented: .constant(true)) {
            JobInspector(jobID: selectedID)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 420)
        }
    }
}

// MARK: - Inspector

struct JobInspector: View {
    @Environment(SchedulerStore.self) private var store
    let jobID: String?

    var body: some View {
        if let job = store.job(id: jobID) {
            Form {
                InspectorHeader(name: job.name, clientName: job.clientName, state: job.state)
                InspectorSchedule(
                    nextRun: job.nextRun, plannedWake: job.plannedWake,
                    repeatText: job.repeatText, estimatedMinutes: job.estimatedMinutes)
                InspectorLaunch(method: job.method, command: job.command, workingDirectory: job.workingDirectory)
                InspectorResources(
                    jobName: job.name, expectedCpu: job.expectedCpu, expectedGpu: job.expectedGpu,
                    intensity: job.intensity)
                InspectorPower(store: store, jobID: job.id, intensity: job.intensity)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No job selected", systemImage: "calendar.badge.clock",
                description: Text("Select a job to see its schedule, resources and power rules."))
        }
    }
}

struct InspectorHeader: View {
    let name: String
    let clientName: String
    let state: JobState

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title3.weight(.semibold))
                Text(clientName).foregroundStyle(.secondary)
                StateBadge(state: state)
            }
        }
    }
}

struct InspectorSchedule: View {
    let nextRun: Date?
    let plannedWake: Date?
    let repeatText: String
    let estimatedMinutes: Int

    var body: some View {
        Section("Schedule") {
            LabeledContent("Starts") {
                if let nextRun { WhenText(date: nextRun) } else { Text("Running now") }
            }
            LabeledContent("Mac wakes") {
                if let plannedWake { WhenText(date: plannedWake) } else { Text("Not booked") }
            }
            LabeledContent("Repeats", value: repeatText)
            LabeledContent("Estimate", value: "\(estimatedMinutes) min")
        }
    }
}

struct InspectorLaunch: View {
    let method: String
    let command: String
    let workingDirectory: String?

    var body: some View {
        Section("Launch") {
            LabeledContent("Method", value: method)
            MonospacedLine(text: command)
            if let workingDirectory {
                LabeledContent("In") { MonospacedLine(text: workingDirectory) }
            }
        }
    }
}

struct InspectorResources: View {
    @Environment(SchedulerStore.self) private var store
    let jobName: String
    let expectedCpu: Int
    let expectedGpu: Int
    let intensity: Intensity

    var body: some View {
        Section("Resources") {
            LabeledContent("Level") { IntensityBadge(level: intensity) }
            ResourceRow(title: "CPU", expected: expectedCpu, measuredAverage: lastRun?.avgCpu, measuredPeak: lastRun?.peakCpu)
            ResourceRow(title: "GPU", expected: expectedGpu, measuredAverage: lastRun?.avgGpu, measuredPeak: lastRun?.peakGpu)
        }
    }

    private var lastRun: MockRun? {
        store.latestRun(forJobNamed: jobName)
    }
}

struct ResourceRow: View {
    let title: LocalizedStringKey
    let expected: Int
    let measuredAverage: Int?
    let measuredPeak: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("expected \(expected)%").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(measuredAverage ?? expected), total: 100)
            if let measuredAverage, let measuredPeak {
                Text("Last run: average \(measuredAverage)%, peak \(measuredPeak)%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct InspectorPower: View {
    @Bindable var store: SchedulerStore
    let jobID: String
    let intensity: Intensity

    var body: some View {
        Section("Power") {
            Stepper(
                "Minimum battery: \(store[minimumBatteryFor: jobID])%",
                value: $store[minimumBatteryFor: jobID], in: 30...100, step: 5)
            Toggle("Allow on battery", isOn: $store[allowHighOnBatteryFor: jobID])
                .disabled(intensity != .high)
            Text(policyText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var policyText: LocalizedStringKey {
        switch intensity {
        case .low: "Low jobs always run, unless the battery is below the 30% floor."
        case .medium: "Medium jobs on battery need more than 80%. On AC they always run."
        case .high: "High jobs need AC power, or battery above 60% if allowed here."
        }
    }
}

#Preview {
    QueueView()
        .environment(SchedulerStore())
        .frame(width: 1000, height: 600)
}
