import SwiftUI
import UIKit

// MARK: - Accent palette

/// Restrained accent colours used across the vibrant card surfaces.
/// Every colour is defined per appearance so it stays legible on the
/// matching card surface.
enum HMAccent: String, CaseIterable, Identifiable, Sendable {
    case jade
    case coral
    case lavender
    case sky
    case amber

    var id: String { rawValue }

    /// Foreground-safe accent, dynamic for light and dark appearances.
    var color: Color {
        Color(uiColor: UIColor { traits in
            switch (self, traits.userInterfaceStyle) {
            case (.jade, .dark): return UIColor(red: 0.45, green: 0.85, blue: 0.69, alpha: 1.0)
            case (.jade, _): return UIColor(red: 0.11, green: 0.54, blue: 0.42, alpha: 1.0)

            case (.coral, .dark): return UIColor(red: 1.00, green: 0.60, blue: 0.53, alpha: 1.0)
            case (.coral, _): return UIColor(red: 0.79, green: 0.31, blue: 0.28, alpha: 1.0)

            case (.lavender, .dark): return UIColor(red: 0.73, green: 0.69, blue: 0.99, alpha: 1.0)
            case (.lavender, _): return UIColor(red: 0.44, green: 0.39, blue: 0.78, alpha: 1.0)

            case (.sky, .dark): return UIColor(red: 0.49, green: 0.78, blue: 1.00, alpha: 1.0)
            case (.sky, _): return UIColor(red: 0.16, green: 0.47, blue: 0.76, alpha: 1.0)

            case (.amber, .dark): return UIColor(red: 1.00, green: 0.78, blue: 0.42, alpha: 1.0)
            case (.amber, _): return UIColor(red: 0.68, green: 0.46, blue: 0.07, alpha: 1.0)
            }
        })
    }

    /// Soft tinted surface suitable as a card background fill.
    var soft: Color {
        Color(uiColor: UIColor { traits in
            switch (self, traits.userInterfaceStyle) {
            case (.jade, .dark): return UIColor(red: 0.13, green: 0.24, blue: 0.21, alpha: 1.0)
            case (.jade, _): return UIColor(red: 0.90, green: 0.97, blue: 0.94, alpha: 1.0)

            case (.coral, .dark): return UIColor(red: 0.27, green: 0.17, blue: 0.17, alpha: 1.0)
            case (.coral, _): return UIColor(red: 1.00, green: 0.93, blue: 0.92, alpha: 1.0)

            case (.lavender, .dark): return UIColor(red: 0.21, green: 0.19, blue: 0.31, alpha: 1.0)
            case (.lavender, _): return UIColor(red: 0.94, green: 0.93, blue: 1.00, alpha: 1.0)

            case (.sky, .dark): return UIColor(red: 0.13, green: 0.22, blue: 0.30, alpha: 1.0)
            case (.sky, _): return UIColor(red: 0.91, green: 0.96, blue: 1.00, alpha: 1.0)

            case (.amber, .dark): return UIColor(red: 0.26, green: 0.21, blue: 0.12, alpha: 1.0)
            case (.amber, _): return UIColor(red: 1.00, green: 0.96, blue: 0.88, alpha: 1.0)
            }
        })
    }

    /// Gentle two-stop gradient for emphasis surfaces.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.85), color.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Card styling

extension View {
    /// Wrap a view in the standard vibrant card surface.
    func hmCard(accent: HMAccent = .jade) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(accent.soft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(accent.color.opacity(0.22), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
    }
}

// MARK: - Section heading

struct HMSectionHeading: View {
    private let title: String
    private let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metric tile

struct HMMetricTile: View {
    private let title: String
    private let value: String
    private let unit: String
    private let symbol: String
    private let accent: HMAccent
    private let caption: String?

    init(
        title: String,
        value: String,
        unit: String = "",
        symbol: String,
        accent: HMAccent,
        caption: String? = nil
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.symbol = symbol
        self.accent = accent
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hmCard(accent: accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [title, value]
        if !unit.isEmpty { parts.append(unit) }
        if let caption, !caption.isEmpty { parts.append(caption) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Score ring

struct HMScoreRing: View {
    private let value: Double?
    private let accent: HMAccent
    private let label: String

    init(value: Double?, accent: HMAccent, label: String) {
        self.value = value
        self.accent = accent
        self.label = label
    }

    private var validValue: Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(0.10),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                if let validValue {
                    Circle()
                        .trim(from: 0, to: CGFloat(validValue / 100))
                        .stroke(
                            accent.color,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(textValue)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(validValue == nil ? Color.secondary : Color.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(10)
            }
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)

            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(validValue == nil ? "暂无数据" : textValue)")
    }

    private var textValue: String {
        guard let validValue else { return "—" }
        if validValue == validValue.rounded() {
            return String(Int(validValue))
        }
        return String(validValue)
    }
}

// MARK: - Mini bars

struct HMMiniBars: View {
    private let values: [Double?]
    private let accent: HMAccent
    private let accessibilitySummary: String

    init(values: [Double?], accent: HMAccent, accessibilitySummary: String) {
        self.values = values
        self.accent = accent
        self.accessibilitySummary = accessibilitySummary
    }

    private var sanitizedValues: [Double?] {
        values.map { raw in
            guard let raw, raw.isFinite, raw >= 0 else { return nil }
            return raw
        }
    }

    private var maximum: Double {
        sanitizedValues.compactMap { $0 }.max() ?? 0
    }

    var body: some View {
        let sanitized = sanitizedValues
        let maxFinite = maximum

        GeometryReader { proxy in
            let count = max(sanitized.count, 1)
            let spacing: CGFloat = 4
            let barWidth = max(
                (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count),
                1
            )

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(sanitized.indices, id: \.self) { index in
                    bar(for: sanitized[index], maxFinite: maxFinite, width: barWidth)
                }
            }
            .frame(height: proxy.size.height, alignment: .bottom)
        }
        .frame(height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func bar(for value: Double?, maxFinite: Double, width: CGFloat) -> some View {
        if let value, maxFinite > 0 {
            let ratio = CGFloat(value / maxFinite)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent.color)
                .frame(width: width, height: ratio * 48)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            // Missing sample: reserve the slot without inventing a height.
            Color.clear
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Help text

struct HMHelpText: View {
    private let text: String
    private let title: String

    @Environment(\.hmDisplayMode) private var displayMode
    @State private var isExpanded = false

    init(text: String, title: String = "说明") {
        self.text = text
        self.title = title
    }

    var body: some View {
        switch displayMode {
        case .classic:
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .cards:
            DisclosureGroup(title, isExpanded: $isExpanded) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .tint(.secondary)
        }
    }
}
