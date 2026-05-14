import SwiftUI

/// Top-of-dashboard summary strip: greeting + 4 big "today" numbers + quality pill + alert bell.
struct HeroHeader: View {
    let snapshot: DashboardSnapshot
    let onAlertsTap: () -> Void
    let onQualityTap: () -> Void
    let onMetricTap: (MetricRoute) -> Void

    init(snapshot: DashboardSnapshot,
         onAlertsTap: @escaping () -> Void,
         onQualityTap: @escaping () -> Void,
         onMetricTap: @escaping (MetricRoute) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.onAlertsTap = onAlertsTap
        self.onQualityTap = onQualityTap
        self.onMetricTap = onMetricTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text(dateLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                qualityPill
                Button(action: onAlertsTap) { alertsBell }
                    .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 14) {
                heroMetric(icon: "figure.walk",
                           value: snapshot.activity.todaySteps.map { "\($0)" } ?? "—",
                           label: "步数",
                           tint: CardTheme.activity.primary,
                           route: .steps)
                heroMetric(icon: "flame.fill",
                           value: snapshot.activity.todayActiveKcal.map { String(format: "%.0f", $0) } ?? "—",
                           label: "活动 kcal",
                           tint: CardTheme.diet.primary,
                           route: .activeKcal)
                heroMetric(icon: "flame",
                           value: snapshot.deficit.todayDeficit.map { String(format: "%+.0f", $0) } ?? "—",
                           label: "热量缺口",
                           tint: CardTheme.deficit.primary,
                           route: .deficit)
                heroMetric(icon: "figure.arms.open",
                           value: snapshot.body_.latestWeight.map { String(format: "%.1f", $0) } ?? "—",
                           label: "体重 kg",
                           tint: CardTheme.body.primary,
                           route: .weight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var qualityPill: some View {
        Button(action: onQualityTap) {
            HStack(spacing: 4) {
                Circle().fill(qualityColor).frame(width: 7, height: 7)
                Text(qualityLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var alertsBell: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: snapshot.unackAlertCount > 0 ? "bell.fill" : "bell")
                .foregroundStyle(snapshot.criticalAlertCount > 0 ? .red
                                 : (snapshot.unackAlertCount > 0 ? .orange : .secondary))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
            if snapshot.unackAlertCount > 0 {
                Text("\(min(snapshot.unackAlertCount, 99))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .padding(.horizontal, 3)
                    .background(snapshot.criticalAlertCount > 0 ? Color.red : Color.orange,
                                in: Capsule())
                    .offset(x: 6, y: -4)
            }
        }
    }

    private func heroMetric(icon: String, value: String, label: String, tint: Color,
                            route: MetricRoute) -> some View {
        Button { onMetricTap(route) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    private var qualityColor: Color {
        guard let c = snapshot.quality?.completenessScore else { return .gray }
        if c >= 0.8 { return .green }
        if c >= 0.5 { return .orange }
        return .red
    }

    private var qualityLabel: String {
        guard let c = snapshot.quality?.completenessScore else { return "数据待对账" }
        return String(format: "完整度 %.0f%%", c * 100)
    }
}
