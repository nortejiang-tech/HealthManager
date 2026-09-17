import SwiftUI

/// 趋势首页头部：问候 + 数据状态胶囊 + 待检查铃铛。
/// v0.6 精简：原「四个今日大数」与下方指标卡片完全重复，已移除（§6.2）——
/// 首页直接看到卡片趋势与进入详情的动作。
struct HeroHeader: View {
    let snapshot: DashboardSnapshot
    let onAlertsTap: () -> Void
    let onQualityTap: () -> Void

    init(snapshot: DashboardSnapshot,
         onAlertsTap: @escaping () -> Void,
         onQualityTap: @escaping () -> Void,
         onMetricTap: @escaping (MetricRoute) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.onAlertsTap = onAlertsTap
        self.onQualityTap = onQualityTap
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
                    .accessibilityLabel(alertsAccessibilityLabel)
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

    /// 铃铛角标显示「未确认告警涉及的指标类数」——历史长串红点总数不在此堆叠（§6.2）；
    /// 详情页仍可看全部历史与原始告警。
    @ViewBuilder
    private var alertsBell: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: snapshot.unackAlertCount > 0 ? "bell.fill" : "bell")
                .foregroundStyle(snapshot.criticalAlertCount > 0 ? .red
                                 : (snapshot.unackAlertCount > 0 ? .orange : .secondary))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
            if snapshot.unackMetricCount > 0 {
                Text("\(min(snapshot.unackMetricCount, 99))类")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 16, minHeight: 14)
                    .background(snapshot.criticalAlertCount > 0 ? Color.red : Color.orange,
                                in: Capsule())
                    .offset(x: 8, y: -4)
            }
        }
    }

    private var alertsAccessibilityLabel: String {
        snapshot.unackMetricCount > 0
            ? "有 \(snapshot.unackMetricCount) 类数据待检查"
            : "没有待检查的数据提醒"
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
