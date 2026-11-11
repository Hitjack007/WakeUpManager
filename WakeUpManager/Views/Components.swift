//
//  Components.swift
//  WakeUpManager
//
//  Small shared pieces used across the mockup screens.
//

import SwiftUI

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
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
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

/// A titled rounded container, used on the overview screen.
struct Card<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

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
