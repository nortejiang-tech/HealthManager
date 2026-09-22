import SwiftUI
import Charts

struct DeficitCard: View {
    let data: DeficitCardData

    var body: some View {
        DashboardCard(
            theme: .deficit, icon: "flame.fill", title: "热量缺口",
            accessory: { TrendChip(series: data.last7Days, theme: .deficit) }
        ) {
            if let d = data.todayDeficit {
                CardMetric(
                    value: String(format: "%+.0f", d),
                    unit: "kcal",
                    theme: .deficit
                )
                Text(d >= 0 ? "今日缺口（消耗 − 摄入）" : "今日盈余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                CardMetric(value: "—", unit: nil)
                Text(missingReason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !data.last7Days.isEmpty {
                Chart(data.last7Days) { d in
                    BarMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("缺口", d.value)
                    )
                    .foregroundStyle(d.value >= 0
                                     ? AnyShapeStyle(CardTheme.deficit.gradient)
                                     : AnyShapeStyle(HMColors.warning.opacity(0.75)))
                    .cornerRadius(2)
                }
                .frame(height: 52)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis(.hidden)
            } else {
                CardEmptyState(text: "近 7 日无足够数据")
                    .frame(height: 52)
            }

            // 降密度（v0.8.2 design-qa）：原「消耗/摄入」双 Label 与计算条件脚注已移除——
            // 缺口构成与口径说明在详情页「当日明细」有完整呈现，卡片只保留大数 + 定义 + 走势。
        }
    }

    private var missingReason: String {
        if data.energy.activeKcal == nil { return "缺少有效活动能量" }
        if data.energy.basalKcal == nil { return "缺少有效基础代谢" }
        switch data.energy.intake {
        case .noMeals: return "今天还没有饮食记录"
        case .incomplete: return "今天的饮食热量记录不完整"
        case .complete: return "现有记录不足以计算热量缺口"
        }
    }
}
