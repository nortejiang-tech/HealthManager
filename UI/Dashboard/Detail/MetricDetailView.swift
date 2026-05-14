import SwiftUI
import Charts

/// One-metric drill-in. Renders a big Swift Chart with a 周/月/年 segmented switcher,
/// summary statistics, and a definition footnote. Used for every dashboard card.
struct MetricDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let config: MetricDetailConfig

    @State private var period: MetricPeriod = .week
    @State private var points: [MetricPoint] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                periodPicker

                summaryHeader

                chartSection

                statsGrid

                Text(config.footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .navigationTitle(config.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: period) { await load() }
    }

    // MARK: - Sections

    private var periodPicker: some View {
        Picker("时段", selection: $period) {
            ForEach(MetricPeriod.allCases) { p in
                Text(p.label).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headerValue)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(config.theme.primary)
                    .monospacedDigit()
                if !headerValue.contains("—"), let unit = config.unit {
                    Text(unit)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(periodRangeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        if points.contains(where: { $0.value != nil }) {
            chartView
                .frame(height: 220)
                .padding(.vertical, 6)
        } else if let err = loadError {
            Text(err)
                .font(.footnote)
                .foregroundStyle(.red)
        } else {
            CardEmptyState(text: "该时段暂无数据")
                .frame(height: 220)
        }
    }

    @ViewBuilder
    private var chartView: some View {
        let plotPoints = points.compactMap { p -> (Date, Double)? in
            guard let v = p.value else { return nil }
            return (p.date, v)
        }
        Chart {
            ForEach(plotPoints, id: \.0) { item in
                switch config.chartStyle {
                case .bar:
                    BarMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.gradient)
                    .cornerRadius(3)
                case .line:
                    LineMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.gradient)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.primary)
                    .symbolSize(36)
                case .area:
                    LineMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.primary)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.primary.opacity(0.18))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .year ? 6 : 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat, centered: false)
                    .font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.system(size: 10))
            }
        }
    }

    private var statsGrid: some View {
        let values = points.compactMap { $0.value }
        let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let mn = values.min()
        let mx = values.max()
        let last = values.last
        return HStack(spacing: 12) {
            statCell(label: "平均", value: avg)
            statCell(label: "最高", value: mx)
            statCell(label: "最低", value: mn)
            statCell(label: "最新", value: last)
        }
    }

    private func statCell(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map { config.format($0) } ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Derived

    private var headerLabel: String {
        switch config.summary {
        case .latest: return "最新"
        case .average: return "平均"
        case .total: return "合计"
        }
    }

    private var headerValue: String {
        let values = points.compactMap { $0.value }
        guard !values.isEmpty else { return "—" }
        switch config.summary {
        case .latest: return values.last.map { config.format($0) } ?? "—"
        case .average:
            let avg = values.reduce(0, +) / Double(values.count)
            return config.format(avg)
        case .total:
            return config.format(values.reduce(0, +))
        }
    }

    private var periodRangeLabel: String {
        guard !points.isEmpty else { return "" }
        let first = points.first?.date ?? Date()
        let last = points.last?.date ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = period == .year ? "yyyy年M月" : "M月d日"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private var xAxisFormat: Date.FormatStyle {
        switch period {
        case .week: return .dateTime.weekday(.narrow)
        case .month: return .dateTime.day().month(.narrow)
        case .year: return .dateTime.month(.narrow)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.compactMap { $0.value }
        guard let mn = values.min(), let mx = values.max() else { return 0...1 }
        if mn == mx {
            return (mn - 1)...(mx + 1)
        }
        let span = mx - mn
        let pad = span * 0.15
        return (mn - pad)...(mx + pad)
    }

    // MARK: - Load

    private func load() async {
        do {
            let loader = DashboardLoader(database: environment.database)
            let pts = try await loader.loadSeries(
                table: config.table,
                column: config.column,
                period: period,
                aggregation: config.aggregation
            )
            await MainActor.run {
                self.points = pts
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "加载失败：\(error.localizedDescription)"
                self.points = []
            }
        }
    }
}

/// Static config for a single metric detail view.
struct MetricDetailConfig {
    enum Summary { case latest, average, total }
    enum ChartStyle { case bar, line, area }

    let title: String
    let unit: String?
    let table: String
    let column: String
    let theme: CardTheme
    let chartStyle: ChartStyle
    let summary: Summary
    let aggregation: SeriesAggregation
    /// Free-text caption shown under the chart (definition, source notes).
    let footnote: String
    /// Closure that turns a double value into its display string.
    let format: (Double) -> String

    static let weight = MetricDetailConfig(
        title: "体重",
        unit: "kg",
        table: "body_metrics_daily",
        column: "weight_kg",
        theme: .body,
        chartStyle: .area,
        summary: .latest,
        aggregation: .latest,
        footnote: "数据来自 Apple 健康 · 每日记录最后一次称重；年视图为周均值。",
        format: { String(format: "%.1f", $0) }
    )

    static let bodyFat = MetricDetailConfig(
        title: "体脂率",
        unit: "%",
        table: "body_metrics_daily",
        column: "body_fat_pct",
        theme: .body,
        chartStyle: .area,
        summary: .latest,
        aggregation: .latest,
        footnote: "数据来自 Apple 健康 · 体脂率换算为百分比展示。",
        format: { String(format: "%.1f", $0 * 100) }
    )

    static let steps = MetricDetailConfig(
        title: "步数",
        unit: "步",
        table: "activity_metrics_daily",
        column: "step_count",
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        aggregation: .sum,
        footnote: "Apple 健康每日步数汇总；月/年视图按桶累计或按周均值。",
        format: { String(format: "%.0f", $0) }
    )

    static let activeKcal = MetricDetailConfig(
        title: "活动能量",
        unit: "kcal",
        table: "activity_metrics_daily",
        column: "active_energy_kcal",
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        aggregation: .sum,
        footnote: "Apple 健康每日活动能量（不含基础代谢）。",
        format: { String(format: "%.0f", $0) }
    )

    static let restingHR = MetricDetailConfig(
        title: "静息心率",
        unit: "bpm",
        table: "activity_metrics_daily",
        column: "resting_hr_bpm",
        theme: .heart,
        chartStyle: .line,
        summary: .latest,
        aggregation: .average,
        footnote: "Apple 健康静息心率（多源时取均值）。",
        format: { String(format: "%.0f", $0) }
    )

    static let hrv = MetricDetailConfig(
        title: "心率变异性",
        unit: "ms",
        table: "activity_metrics_daily",
        column: "hrv_ms",
        theme: .heart,
        chartStyle: .line,
        summary: .average,
        aggregation: .average,
        footnote: "HKHeartRateVariabilitySDNN · 越高一般代表恢复越好。",
        format: { String(format: "%.0f", $0) }
    )

    static let sleep = MetricDetailConfig(
        title: "睡眠",
        unit: "小时",
        table: "activity_metrics_daily",
        column: "sleep_seconds",
        theme: .sleep,
        chartStyle: .bar,
        summary: .average,
        aggregation: .average,
        footnote: "汇总每晚 Asleep 状态时长（不含 inBed）。",
        format: { (v: Double) in String(format: "%.1f", v / 3600.0) }
    )

    static let exercise = MetricDetailConfig(
        title: "锻炼时长",
        unit: "分钟",
        table: "activity_metrics_daily",
        column: "exercise_minutes",
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        aggregation: .sum,
        footnote: "Apple 健康 Apple Exercise Time。",
        format: { String(format: "%.0f", $0) }
    )

    static let distance = MetricDetailConfig(
        title: "距离",
        unit: "公里",
        table: "activity_metrics_daily",
        column: "distance_m",
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        aggregation: .sum,
        footnote: "步行 + 跑步距离合计。",
        format: { String(format: "%.2f", $0 / 1000) }
    )
}
