import SwiftUI
import Charts

struct SleepCard: View {
    let data: SleepCardData

    var body: some View {
        DashboardCard(theme: .sleep, icon: "bed.double.fill", title: "睡眠") {
            if let hours = data.lastNightHours, hours > 0 {
                CardMetric(value: formatHours(hours), unit: nil, theme: .sleep)
            } else {
                CardMetric(value: "—", unit: nil)
            }

            Text("昨晚")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if data.last7Days.contains(where: { $0.value > 0 }) {
                Chart(data.last7Days) { d in
                    BarMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("时长", d.value)
                    )
                    .foregroundStyle(CardTheme.sleep.gradient)
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
                CardEmptyState(text: "近 7 日无数据")
                    .frame(height: 52)
            }
        }
    }

    private func formatHours(_ h: Double) -> String {
        let hours = Int(h)
        let mins = Int((h - Double(hours)) * 60)
        return "\(hours)h \(mins)m"
    }
}
