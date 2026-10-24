import SwiftUI
import Charts

struct BodyCard: View {
    let data: BodyCardData

    var body: some View {
        DashboardCard(
            theme: .body, icon: "figure.arms.open", title: "体重 / 体成分",
            accessory: { Image(systemName: "clock").foregroundStyle(.secondary) }
        ) {
            if let w = data.latestWeight {
                CardMetric(value: WeightAggregationPolicy.displayKilograms(w), unit: "kg", theme: .body)
            } else {
                CardMetric(value: "—", unit: nil)
            }

            Text((data.weightEvidence.map { $0.day + " · " } ?? "") + WeightProjection.caption(data.weightEvidence)).font(.caption2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let fat = data.latestBodyFatPct {
                    Text(String(format: "体脂 %.1f%%", fat * 100))
                }
                if let bmi = data.latestBmi {
                    Text(String(format: "BMI %.1f", bmi))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if data.last30Days.count >= 2 {
                Chart(data.last30Days) { d in
                    LineMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("体重", d.value)
                    )
                    .foregroundStyle(CardTheme.body.gradient)
                    .interpolationMethod(.linear)
                    AreaMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("体重", d.value)
                    )
                    .foregroundStyle(CardTheme.body.primary.opacity(0.18))
                    .interpolationMethod(.linear)
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
