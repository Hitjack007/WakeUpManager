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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
