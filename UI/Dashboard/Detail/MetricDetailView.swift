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
    @State private var inspectedDate: Date?

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
        .task(id: period) {
            inspectedDate = nil
            await load()
        }
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
            Text(inspectedLabel ?? headerLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayValue)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(config.theme.primary)
                    .monospacedDigit()
                if !displayValue.contains("—"), let unit = config.unit {
                    Text(unit)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(inspectedDateLabel ?? periodRangeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var inspectedLabel: String? {
        inspectedDate == nil ? nil : "选中"
    }

    private var inspectedDateLabel: String? {
        guard let d = inspectedDate else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = period == .year ? "yyyy年 第w周" : "M月d日 EEEE"
        return f.string(from: d)
    }

    private var displayValue: String {
        if let d = inspectedDate, let p = nearestPoint(to: d), let v = p.value {
            return config.format(v)
        }
        return headerValue
    }

    private func nearestPoint(to date: Date) -> MetricPoint? {
        guard !points.isEmpty else { return nil }
        return points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
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
        let inspected = inspectedDate.flatMap { nearestPoint(to: $0) }

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

            // Inspector marks: drawn on top so they're always visible.
            if let inspected, let v = inspected.value {
                RuleMark(x: .value("日期", inspected.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(
                    x: .value("日期", inspected.date, unit: .day),
                    y: .value(config.title, v)
                )
                .foregroundStyle(config.theme.primary)
                .symbolSize(120)
                .symbol(.circle)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .year ? 6 : 5)) { _ in
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let plotFrame: CGRect = {
                                    if let anchor = proxy.plotFrame {
                                        return geo[anchor]
                                    }
                                    return geo.frame(in: .local)
                                }()
                                let relativeX = drag.location.x - plotFrame.origin.x
                                if let d: Date = proxy.value(atX: relativeX) {
                                    inspectedDate = d
                                }
                            }
                            .onEnded { _ in
                                // Keep the inspection sticky so users can read the value;
                                // tapping elsewhere or switching period clears it via .task(id:).
                            }
                    )
                    .onTapGesture(count: 2) { inspectedDate = nil }
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
            let pts: [MetricPoint]
            switch config.source {
            case .tableColumn(let table, let column, let aggregation):
                pts = try await loader.loadSeries(
                    table: table,
                    column: column,
                    period: period,
                    aggregation: aggregation
                )
            case .diet:
                pts = try await loader.loadDietSeries(period: period)
            case .deficit:
                pts = try await loader.loadDeficitSeries(period: period)
            }
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
    /// Where this detail page reads its series from. `tableColumn` covers everything
    /// that's already projected into `activity_metrics_daily` / `body_metrics_daily`;
    /// `diet` / `deficit` are derived from `meal_records` and need bespoke SQL.
    enum Source {
        case tableColumn(String, String, SeriesAggregation)
        case diet
        case deficit
    }

    let title: String
    let unit: String?
    let source: Source
    let theme: CardTheme
    let chartStyle: ChartStyle
    let summary: Summary
    /// Free-text caption shown under the chart (definition, source notes).
    let footnote: String
    /// Closure that turns a double value into its display string.
    let format: (Double) -> String

    static let weight = MetricDetailConfig(
        title: "体重",
        unit: "kg",
        source: .tableColumn("body_metrics_daily", "weight_kg", .latest),
        theme: .body,
        chartStyle: .area,
        summary: .latest,
        footnote: "数据来自 Apple 健康 · 每日记录最后一次称重；年视图为周均值。",
        format: { String(format: "%.1f", $0) }
    )

    static let bodyFat = MetricDetailConfig(
        title: "体脂率",
        unit: "%",
        source: .tableColumn("body_metrics_daily", "body_fat_pct", .latest),
        theme: .body,
        chartStyle: .area,
        summary: .latest,
        footnote: "数据来自 Apple 健康 · 体脂率换算为百分比展示。",
        format: { String(format: "%.1f", $0 * 100) }
    )

    static let steps = MetricDetailConfig(
        title: "步数",
        unit: "步",
        source: .tableColumn("activity_metrics_daily", "step_count", .sum),
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        footnote: "Apple 健康每日步数汇总；月/年视图按桶累计或按周均值。",
        format: { String(format: "%.0f", $0) }
    )

    static let activeKcal = MetricDetailConfig(
        title: "活动能量",
        unit: "kcal",
        source: .tableColumn("activity_metrics_daily", "active_energy_kcal", .sum),
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        footnote: "Apple 健康每日活动能量（不含基础代谢）。",
        format: { String(format: "%.0f", $0) }
    )

    static let restingHR = MetricDetailConfig(
        title: "静息心率",
        unit: "bpm",
        source: .tableColumn("activity_metrics_daily", "resting_hr_bpm", .average),
        theme: .heart,
        chartStyle: .line,
        summary: .latest,
        footnote: "Apple 健康静息心率（多源时取均值）。",
        format: { String(format: "%.0f", $0) }
    )

    static let hrv = MetricDetailConfig(
        title: "心率变异性",
        unit: "ms",
        source: .tableColumn("activity_metrics_daily", "hrv_ms", .average),
        theme: .heart,
        chartStyle: .line,
        summary: .average,
        footnote: "HKHeartRateVariabilitySDNN · 越高一般代表恢复越好。",
        format: { String(format: "%.0f", $0) }
    )

    static let sleep = MetricDetailConfig(
        title: "睡眠",
        unit: "小时",
        source: .tableColumn("activity_metrics_daily", "sleep_seconds", .average),
        theme: .sleep,
        chartStyle: .bar,
        summary: .average,
        footnote: "汇总每晚 Asleep 状态时长（不含 inBed）。",
        format: { (v: Double) in String(format: "%.1f", v / 3600.0) }
    )

    static let exercise = MetricDetailConfig(
        title: "锻炼时长",
        unit: "分钟",
        source: .tableColumn("activity_metrics_daily", "exercise_minutes", .sum),
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        footnote: "Apple 健康 Apple Exercise Time。",
        format: { String(format: "%.0f", $0) }
    )

    static let distance = MetricDetailConfig(
        title: "距离",
        unit: "公里",
        source: .tableColumn("activity_metrics_daily", "distance_m", .sum),
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        footnote: "步行 + 跑步距离合计。",
        format: { String(format: "%.2f", $0 / 1000) }
    )

    static let diet = MetricDetailConfig(
        title: "饮食热量",
        unit: "kcal",
        source: .diet,
        theme: .diet,
        chartStyle: .bar,
        summary: .average,
        footnote: "按日合计的 meal_records.calories_kcal · 年视图为周均。",
        format: { String(format: "%.0f", $0) }
    )

    static let deficit = MetricDetailConfig(
        title: "热量缺口",
        unit: "kcal",
        source: .deficit,
        theme: .deficit,
        chartStyle: .bar,
        summary: .average,
        footnote: "缺口 = 活动能量 + 基础代谢 − 摄入 · 正值代表赤字。",
        format: { String(format: "%+.0f", $0) }
    )
}
