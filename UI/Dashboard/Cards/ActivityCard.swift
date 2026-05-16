import SwiftUI
import Charts

struct ActivityCard: View {
    let data: ActivityCardData

    var body: some View {
        DashboardCard(
            theme: .activity, icon: "figure.walk", title: "活动",
            accessory: { TrendChip(series: data.last7Days, theme: .activity) }
        ) {
            CardMetric(
                value: data.todayActiveKcal.map { String(format: "%.0f", $0) } ?? "—",
                unit: "kcal",
                theme: .activity
            )

            HStack(spacing: 10) {
                if let steps = data.todaySteps, steps > 0 {
                    Label("\(steps) 步", systemImage: "figure.walk")
                        .foregroundStyle(CardTheme.activity.primary)
                }
                if let dist = data.todayDistanceM, dist > 0 {
                    Label(String(format: "%.1f km", dist / 1000), systemImage: "location")
                        .foregroundStyle(.secondary)
                }
                if let mins = data.todayExerciseMin, mins > 0 {
                    Label(String(format: "%.0f 分", mins), systemImage: "stopwatch")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)

            if data.last7Days.contains(where: { $0.value > 0 }) {
                Chart(data.last7Days) { d in
                    BarMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("活动能量", d.value)
                    )
                    .foregroundStyle(CardTheme.activity.gradient)
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
                CardEmptyState(text: "近 7 日无活动能量")
                    .frame(height: 52)
            }
        }
    }
}
