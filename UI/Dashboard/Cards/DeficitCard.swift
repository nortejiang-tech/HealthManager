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
                Text(d >= 0 ? "今日缺口（消耗 - 摄入）" : "今日盈余")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                CardMetric(value: "—", unit: nil)
                Text("待 basal 数据补充")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                if let burned = data.todayBurned {
                    Label(String(format: "消耗 %.0f", burned), systemImage: "arrow.up")
                        .foregroundStyle(CardTheme.deficit.primary)
                }
                if let intake = data.todayIntake {
                    Label(String(format: "摄入 %.0f", intake), systemImage: "arrow.down")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)

            if data.last7Days.contains(where: { $0.value != 0 }) {
                Chart(data.last7Days) { d in
                    BarMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("缺口", d.value)
                    )
                    .foregroundStyle(d.value >= 0
                                     ? AnyShapeStyle(CardTheme.deficit.gradient)
                                     : AnyShapeStyle(Color.orange.opacity(0.7)))
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
        }
    }
}
