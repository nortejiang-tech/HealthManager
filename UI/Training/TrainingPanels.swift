import SwiftUI
import Charts

struct TrainingStatRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { Text(label).foregroundStyle(.secondary); Text(value).fontWeight(.semibold) }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
                }
            }
        }.font(.subheadline).monospacedDigit().accessibilityElement(children: .combine)
    }
}

struct TrainingChartEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

struct TrainingPointChart: View {
    let points: [TrainingMetricValue]
    let label: String
    let color: Color
    var intraday = false
    var body: some View {
        if points.isEmpty { TrainingChartEmpty(text: "\(label)：暂无可用记录") }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Chart(points) { point in
                    PointMark(x: .value("时间", point.date), y: .value(label, point.value))
                        .foregroundStyle(color).symbolSize(intraday ? 14 : 24)
                }
                .frame(height: 120)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYScale(domain: .automatic(includesZero: false))
                .accessibilityLabel("\(label)，\(points.count)个已记录观测点，缺测未补值")
            }
        }
    }
}
