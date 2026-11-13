//
//  QueueView.swift
//  WakeUpManager
//

import SwiftUI

struct QueueView: View {
    @Environment(SchedulerStore.self) private var store
    @State private var selectedID: String?
    @State private var jobPendingCancel: MockJob?

    /// The jobs in three groups, leaving out any group with nothing in it.
    private var groups: [QueueGroup] {
        let running = store.jobs.filter { $0.state == .running || $0.state == .overrunning }
        let waiting = store.jobs
            .filter { $0.state == .scheduled || $0.state == .awaitingApproval }
            .sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
        let finished = store.jobs.filter { [.completed, .failed, .skipped].contains($0.state) }
        return [
            QueueGroup(id: "running", title: "Running now", jobs: running),
            QueueGroup(id: "scheduled", title: "Scheduled", jobs: waiting),
            QueueGroup(id: "finished", title: "Not scheduled", jobs: finished),
        ].filter { !$0.jobs.isEmpty }
    }

    private var list: some View {
        Group {
            if store.jobs.isEmpty {
                ContentUnavailableView(
                    "No jobs yet", systemImage: "calendar.badge.clock",
                    description: Text("Apps and scripts that ask the scheduler to wake this Mac will appear here."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(text: group.title, count: group.jobs.count)
                                VStack(spacing: 8) {
                                    ForEach(group.jobs) { job in
                                        QueueRow(job: job, isSelected: selectedID == job.id)
                                            .onTapGesture { selectedID = selectedID == job.id ? nil : job.id }
                                            .contextMenu {
                                                Button("Cancel Job…", systemImage: "xmark.circle", role: .destructive) {
                                                    jobPendingCancel = job
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var body: some View {
        // The job details are a plain pane beside the list rather than the system inspector column. Opening
        // the system inspector resizes the window while SwiftUI is still laying it out, which can send AppKit
        // into a layout loop that crashes the app.
        HStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.job(id: selectedID) != nil {
                Divider()
                JobInspector(jobID: selectedID, onCancel: { jobPendingCancel = $0 })
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(.background)
            }
        }
        .onExitCommand { selectedID = nil }
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem {
                Button("Cancel Job…", systemImage: "xmark.circle") {
                    jobPendingCancel = store.job(id: selectedID)
                }
                .disabled(store.job(id: selectedID) == nil)
                .help("Remove the selected job and everything planned for it")
            }
        }
        .cancelJobConfirmation($jobPendingCancel) { job in
            if selectedID == job.id { selectedID = nil }
        }
    }
}

// MARK: - The list

struct QueueGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let jobs: [MockJob]
}

struct QueueRow: View {
    let job: MockJob
    var isSelected = false

    var body: some View {
        // One fixed layout whatever the width: the badges sit under the name and the time on the right, so
        // the row never changes shape (and never needs the window to) when the details pane opens.
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: job.state.symbol, tint: job.state.color, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(job.clientName) · \(job.repeatText) · \(job.estimatedMinutes) min")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    IntensityBadge(level: job.intensity)
                    StateBadge(state: job.state)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let next = job.nextRun {
                    WhenText(date: next)
                } else if job.state == .running || job.state == .overrunning {
                    Text("Running now").foregroundStyle(.secondary)
                }
                if let wake = job.plannedWake {
                    Text("wakes \(Text(wake, format: .dateTime.hour().minute()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.5)),
                              lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Inspector

struct JobInspector: View {
    @Environment(SchedulerStore.self) private var store
    let jobID: String?
    let onCancel: (MockJob) -> Void

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
                // Battery rules only matter on a Mac that has a battery.
                if store.hasBattery {
                    InspectorPower(store: store, jobID: job.id, intensity: job.intensity)
                }
                Section {
                    Button(role: .destructive) {
                        onCancel(job)
                    } label: {
                        Label(
                            job.state == .running || job.state == .overrunning ? "Stop and Remove Job…" : "Cancel Job…",
                            systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } footer: {
                    Text("Removes the job and everything planned for it. The app that scheduled it can schedule it again.")
                }
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
        .frame(width: 1100, height: 640)
}

#Preview("Narrow") {
    QueueView()
        .environment(SchedulerStore())
        .frame(width: 620, height: 640)
}
