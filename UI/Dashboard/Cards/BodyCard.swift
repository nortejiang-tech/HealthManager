import SwiftUI
import Charts

struct BodyCard: View {
    let data: BodyCardData

    var body: some View {
        DashboardCard(
            theme: .body, icon: "figure.arms.open", title: "体重 / 体成分",
            accessory: { TrendChip(series: data.last30Days, lowerIsBetter: true, theme: .body) }
        ) {
            if let w = data.latestWeight {
                CardMetric(value: String(format: "%.1f", w), unit: "kg", theme: .body)
            } else {
                CardMetric(value: "—", unit: nil)
            }

            if let fat = data.latestBodyFatPct {
                Text(String(format: "体脂 %.1f%%", fat * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if data.last30Days.count >= 2 {
                Chart(data.last30Days) { d in
                    LineMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("体重", d.value)
                    )
                    .foregroundStyle(CardTheme.body.gradient)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("体重", d.value)
                    )
                    .foregroundStyle(CardTheme.body.primary.opacity(0.18))
                    .interpolationMethod(.catmullRom)
                }
                .frame(height: 52)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            } else {
                CardEmptyState(text: "近 30 日无足够数据")
                    .frame(height: 52)
            }
        }
    }
}
