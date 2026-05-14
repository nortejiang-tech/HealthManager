import SwiftUI

/// Compact ↑/↓ percentage badge comparing the back half of a series to the front half.
/// Used on each card to give Apple Health–style "vs last week" context.
struct TrendChip: View {
    let series: [DatedDouble]
    /// If true, a *lower* value is the goal (e.g. resting heart rate, body fat). The arrow
    /// color flips accordingly: down = green, up = red.
    let lowerIsBetter: Bool
    let theme: CardTheme

    init(series: [DatedDouble], lowerIsBetter: Bool = false, theme: CardTheme) {
        self.series = series
        self.lowerIsBetter = lowerIsBetter
        self.theme = theme
    }

    var body: some View {
        if let trend = compute() {
            HStack(spacing: 2) {
                Image(systemName: trend.direction.systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(String(format: "%.1f%%", abs(trend.percent * 100)))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(color(for: trend.direction))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color(for: trend.direction).opacity(0.12), in: Capsule())
        }
    }

    private struct Trend { let percent: Double; let direction: Direction }
    private enum Direction { case up, down, flat
        var systemImage: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "minus"
            }
        }
    }

    private func compute() -> Trend? {
        let values = series.map { $0.value }.filter { $0.isFinite }
        guard values.count >= 4 else { return nil }
        let halfIdx = values.count / 2
        let front = Array(values.prefix(halfIdx))
        let back = Array(values.suffix(values.count - halfIdx))
        let avgFront = front.reduce(0, +) / Double(front.count)
        let avgBack = back.reduce(0, +) / Double(back.count)
        guard avgFront != 0 else { return nil }
        let delta = (avgBack - avgFront) / abs(avgFront)
        let direction: Direction = abs(delta) < 0.01 ? .flat : (delta > 0 ? .up : .down)
        return Trend(percent: delta, direction: direction)
    }

    private func color(for d: Direction) -> Color {
        switch d {
        case .flat: return .secondary
        case .up: return lowerIsBetter ? .red : theme.primary
        case .down: return lowerIsBetter ? .green : .orange
        }
    }
}
