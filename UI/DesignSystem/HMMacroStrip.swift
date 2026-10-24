import SwiftUI

/// A compact, reusable panel showing the three macronutrients in grams.
///
/// The segmented strip above the cells shows *gram mass* proportions only —
/// never energy percentages, targets, or completion. It is drawn only when all
/// three gram values are valid and their total is finite and greater than zero.
/// Invalid samples (nil, non-finite, negative) render as `—` and are never
/// silently coerced to zero.
struct HMMacroStrip: View {
    private let protein: Double?
    private let fat: Double?
    private let carbs: Double?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(protein: Double?, fat: Double?, carbs: Double?) {
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
    }

    // MARK: - Derived data

    private struct Macro: Identifiable {
        let id: Int
        let title: String
        let raw: Double?
        let accent: HMAccent
    }

    private var macros: [Macro] {
        [
            Macro(id: 0, title: "蛋白质", raw: protein, accent: .coral),
            Macro(id: 1, title: "脂肪", raw: fat, accent: .amber),
            Macro(id: 2, title: "碳水", raw: carbs, accent: .sky),
        ]
    }

    /// A gram value is valid only when present, finite and non-negative.
    private func valid(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return raw
    }

    private var grams: [Double?] { macros.map { valid($0.raw) } }

    private var total: Double { grams.compactMap { $0 }.reduce(0, +) }

    /// The strip needs every sample valid and a positive finite total.
    private var canDrawStrip: Bool {
        grams.count == 3 && grams.allSatisfy { $0 != nil } && total.isFinite && total > 0
    }

    private func text(for raw: Double?) -> String {
        guard let value = valid(raw) else { return "—" }
        return String(format: "%.1f", value)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canDrawStrip {
                Text("三大营养素 · 克数比例")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                proportionStrip
            }
            cells
        }
        .animation(nil, value: protein)
        .animation(nil, value: fat)
        .animation(nil, value: carbs)
    }

    // MARK: - Gram proportion strip (decorative)

    private var proportionStrip: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(grams.enumerated()), id: \.offset) { index, gram in
                    let fraction = CGFloat((gram ?? 0) / total)
                    Rectangle()
                        .fill(macros[index].accent.color)
                        .frame(width: proxy.size.width * fraction)
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule(style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - Cells

    @ViewBuilder
    private var cells: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(macros) { macro in cell(macro, stacked: true) }
            }
        } else {
            HStack(spacing: 12) {
                ForEach(macros) { macro in cell(macro, stacked: false) }
            }
        }
    }

    private func cell(_ macro: Macro, stacked: Bool) -> some View {
        let content = VStack(alignment: stacked ? .leading : .center, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(macro.accent.color.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(macro.title)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text(for: macro.raw))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(macro.accent.color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if valid(macro.raw) != nil {
                    Text("g")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(macro.title)，\(valid(macro.raw) == nil ? "暂无数据" : "\(text(for: macro.raw)) 克")")
        return content
    }
}
