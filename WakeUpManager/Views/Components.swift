//
//  Components.swift
//  WakeUpManager
//
//  Small shared pieces used across the screens.
//

import SwiftUI

// MARK: - Brand colours (the app icon's dawn gradient)

extension Color {
    static let brandIndigo = Color(red: 0.17, green: 0.165, blue: 0.478)
    static let brandCoral = Color(red: 1.0, green: 0.56, blue: 0.42)
}

extension ShapeStyle where Self == LinearGradient {
    /// Indigo fading to coral, the same sky as the app icon.
    static var dawn: LinearGradient {
        LinearGradient(
            colors: [.brandIndigo, Color(red: 0.52, green: 0.30, blue: 0.52), .brandCoral],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Pills

/// A small coloured label, used for intensity levels and job states.
struct Pill: View {
    let text: LocalizedStringKey
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

struct IntensityBadge: View {
    let level: Intensity

    var body: some View {
        Pill(text: level.title, color: level.color)
    }
}

struct StateBadge: View {
    let state: JobState

    var body: some View {
        Pill(text: state.title, color: state.color, symbol: state.symbol)
    }
}

// MARK: - Containers

/// A titled rounded container.
struct Card<Content: View>: View {
    let title: LocalizedStringKey?
    /// Cards side by side can ask for the same minimum height so their edges line up.
    var minHeight: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.5))
        }
    }
}

/// A heading above a block of content.
struct SectionTitle: View {
    let text: LocalizedStringKey
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.title3.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A round icon in a tinted circle, the leading mark on rows and tiles.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

// MARK: - Cancelling a job

extension View {
    /// Asks "are you sure?" whenever `job` is set, and removes the job if the user confirms.
    /// `onCancelled` runs after it is removed, for example to clear a selection.
    func cancelJobConfirmation(_ job: Binding<MockJob?>, onCancelled: ((MockJob) -> Void)? = nil) -> some View {
        modifier(CancelJobConfirmation(job: job, onCancelled: onCancelled))
    }
}

struct CancelJobConfirmation: ViewModifier {
    @Environment(SchedulerStore.self) private var store
    @Binding var job: MockJob?
    var onCancelled: ((MockJob) -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Cancel this job?",
            isPresented: Binding(get: { job != nil }, set: { if !$0 { job = nil } }),
            titleVisibility: .visible,
            presenting: job
        ) { job in
            let running = job.state == .running || job.state == .overrunning
            Button(running ? "Stop and Remove Job" : "Cancel Job", role: .destructive) {
                store.cancelJob(id: job.id)
                onCancelled?(job)
            }
            Button("Keep Job", role: .cancel) {}
        } message: { job in
            let running = job.state == .running || job.state == .overrunning
            Text("\(job.name) will be removed along with every run planned for it\(running ? ", and it will be stopped now" : ""). \(job.clientName) can schedule it again.")
        }
    }
}

// MARK: - Text

/// A date and time in the style used across the app: weekday, hour and minute.
struct WhenText: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct MonospacedLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(3)
    }
}
