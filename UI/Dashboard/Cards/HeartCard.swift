import SwiftUI
import Charts

struct HeartCard: View {
    let data: HeartCardData

    var body: some View {
        DashboardCard(
            theme: .heart, icon: "heart.fill", title: "心率",
            accessory: { TrendChip(series: data.last7Days, lowerIsBetter: true, theme: .heart) }
        ) {
            if let hr = data.todayRestingHR {
                CardMetric(value: String(format: "%.0f", hr), unit: "bpm", theme: .heart)
                Text("静息")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let hr = data.todayAvgHR {
                CardMetric(value: String(format: "%.0f", hr), unit: "bpm", theme: .heart)
                Text("均值")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                CardMetric(value: "—", unit: nil)
            }

            if let hrv = data.todayHRV, hrv > 0 {
                Label(String(format: "HRV %.0f ms", hrv), systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            if data.last7Days.contains(where: { $0.value > 0 }) {
                Chart(data.last7Days) { d in
                    LineMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("BPM", d.value)
                    )
                    .foregroundStyle(CardTheme.heart.gradient)
                    .interpolationMethod(.linear)
                    PointMark(
                        x: .value("日期", d.date, unit: .day),
                        y: .value("BPM", d.value)
                    )
                    .foregroundStyle(CardTheme.heart.primary)
                    .symbolSize(18)
                }
                .frame(height: 52)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            } else {
                CardEmptyState(text: "近 7 日无心率")
                    .frame(height: 52)
            }
        }
    }
}
