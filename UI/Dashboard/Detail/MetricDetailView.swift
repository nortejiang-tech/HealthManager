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
    @State private var deficitBreakdown: DashboardLoader.DeficitBreakdown?
    @State private var dayMeasurements: [DashboardLoader.BodyMeasurementSample] = []
    /// Leading edge (oldest visible day) of the scrollable chart window. Drives the
    /// Apple-Health-style pan; stats/header recompute from whatever is currently visible.
    @State private var scrollPositionX: Date = Calendar.current.startOfDay(for: Date())
    /// Transient selection from `chartXSelection` — nil while no gesture is active. We
    /// copy non-nil values into `inspectedDate` so the selection sticks after release.
    @State private var rawSelection: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                periodPicker

                summaryHeader

                chartSection

                statsGrid

                if case .deficit = config.source {
                    deficitBreakdownCard
                }

                if config.rawSamplesType != nil {
                    dayMeasurementsCard
                }

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
            rawSelection = nil
            deficitBreakdown = nil
            await load()
        }
        .task(id: inspectedDate) {
            await loadInspectedBreakdown()
            await loadDayMeasurements()
        }
        // Selection persists after the finger lifts: only adopt non-nil values, ignore
        // the reset-to-nil that fires on gesture end.
        .onChange(of: rawSelection) { _, newValue in
            if let newValue { inspectedDate = newValue }
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
            HStack(spacing: 6) {
                Text(inspectedLabel ?? headerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if inspectedDate == nil {
                    let trendSeries = visiblePoints.compactMap { p -> DatedDouble? in
                        guard let v = p.value else { return nil }
                        return DatedDouble(date: p.date, value: v)
                    }
                    TrendChip(series: trendSeries, lowerIsBetter: lowerIsBetter, theme: config.theme)
                } else {
                    Button {
                        inspectedDate = nil
                        rawSelection = nil
                    } label: {
                        Text("清除选中")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
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

    private var lowerIsBetter: Bool {
        switch config.title {
        case "静息心率", "体重", "体脂率": return true
        default: return false
        }
    }

    private var inspectedLabel: String? {
        inspectedDate == nil ? nil : "选中"
    }

    private var inspectedDateLabel: String? {
        guard let d = inspectedDate else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = period == .year ? "yyyy年M月d日" : "M月d日 EEEE"
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

    /// Width of the visible window in seconds. Normally the period's pane (周/月/年), but
    /// when the available data spans less than that pane we shrink to the data span so the
    /// bars stretch to fill the chart instead of cramming into a corner.
    private var effectiveVisibleSeconds: TimeInterval {
        let plotted = points.compactMap { $0.value != nil ? $0.date : nil }
        guard let first = plotted.first, let last = plotted.last, last > first else {
            return period.visibleDomainSeconds
        }
        let dataSpan = last.timeIntervalSince(first) + 86_400  // +1 day so the last bar isn't clipped
        return min(period.visibleDomainSeconds, max(dataSpan, 86_400))
    }

    /// The date interval currently scrolled into view.
    private var visibleInterval: DateInterval {
        let end = scrollPositionX.addingTimeInterval(effectiveVisibleSeconds)
        return DateInterval(start: scrollPositionX, end: end)
    }

    /// Points whose date falls inside the visible window — the basis for the summary
    /// header and the 平均 / 最高 / 最低 / 最新 stat cells (so they track the pan).
    private var visiblePoints: [MetricPoint] {
        let interval = visibleInterval
        let filtered = points.filter { interval.contains($0.date) }
        // Before the first layout pass scrollPositionX may not align with data yet;
        // fall back to all points so the header isn't blank on first render.
        return filtered.isEmpty ? points : filtered
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
                    .interpolationMethod(.linear)
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
                    .interpolationMethod(.linear)
                    AreaMark(
                        x: .value("日期", item.0, unit: .day),
                        y: .value(config.title, item.1)
                    )
                    .foregroundStyle(config.theme.primary.opacity(0.18))
                    .interpolationMethod(.linear)
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
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                if let v = value.as(Double.self) {
                    AxisValueLabel { Text(config.format(v)) }
                        .font(.system(size: 10))
                } else {
                    AxisValueLabel().font(.system(size: 10))
                }
            }
        }
        // Apple-Health-style horizontal pan: a fixed-width window scrolls across the
        // full loaded history. Tap to select a day; the header + stats follow the window.
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: effectiveVisibleSeconds)
        .chartScrollPosition(x: $scrollPositionX)
        .chartXSelection(value: $rawSelection)
    }

    private var statsGrid: some View {
        let values = visiblePoints.compactMap { $0.value }
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

    /// Breakdown card for the deficit detail view: shows the three numbers that make
    /// up the selected day's deficit so the user can see how it was computed.
    @ViewBuilder
    private var deficitBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("当日明细").font(.subheadline.weight(.semibold))
                Spacer()
                if inspectedDate == nil {
                    Text("点击图表选中某天").font(.caption2).foregroundStyle(.secondary)
                } else if let b = deficitBreakdown {
                    Text(dayLabel(b.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let b = deficitBreakdown, inspectedDate != nil {
                VStack(spacing: 8) {
                    breakdownRow(
                        icon: "bed.double.fill",
                        label: "基础代谢",
                        value: b.basal,
                        sign: "+",
                        tint: .indigo
                    )
                    breakdownRow(
                        icon: "figure.walk",
                        label: "活动消耗",
                        value: b.active,
                        sign: "+",
                        tint: .orange
                    )
                    breakdownRow(
                        icon: "fork.knife",
                        label: "饮食摄入",
                        value: b.intake,
                        sign: "−",
                        tint: .green
                    )
                    Divider()
                    HStack {
                        Text("热量缺口")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(String(format: "%+.0f kcal", b.deficit))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(b.deficit >= 0 ? config.theme.primary : .red)
                    }
                }
            } else if inspectedDate != nil, deficitBreakdown == nil {
                Text("当日无明细数据").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Lists every raw sample recorded on the inspected day for body metrics
    /// (weight / body fat / BMI), so the user can see each individual weigh-in
    /// behind the day's average.
    @ViewBuilder
    private var dayMeasurementsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("当日全部测量").font(.subheadline.weight(.semibold))
                Spacer()
                if inspectedDate == nil {
                    Text("点击图表选中某天").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(dayMeasurements.count) 次").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if inspectedDate != nil {
                if dayMeasurements.isEmpty {
                    Text("当日无明细记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(dayMeasurements) { m in
                            HStack(alignment: .firstTextBaseline) {
                                Text(timeLabel(m.time))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(measurementLabel(m.value))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                    Text(m.source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if dayMeasurements.count > 1 {
                            Divider()
                            HStack {
                                Text("当日平均").font(.callout.weight(.semibold))
                                Spacer()
                                Text(measurementLabel(averageMeasurement))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(config.theme.primary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var averageMeasurement: Double {
        guard !dayMeasurements.isEmpty else { return 0 }
        return dayMeasurements.map(\.value).reduce(0, +) / Double(dayMeasurements.count)
    }

    private func measurementLabel(_ value: Double) -> String {
        config.format(value) + (config.unit.map { " \($0)" } ?? "")
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func loadDayMeasurements() async {
        guard let hkType = config.rawSamplesType else { return }
        guard let d = inspectedDate, let target = nearestPoint(to: d)?.date else {
            await MainActor.run { dayMeasurements = [] }
            return
        }
        do {
            let loader = DashboardLoader(database: environment.database)
            let list = try await loader.loadDayMeasurements(hkType: hkType, day: target)
            await MainActor.run { dayMeasurements = list }
        } catch {
            await MainActor.run { dayMeasurements = [] }
        }
    }

    private func breakdownRow(icon: String, label: String, value: Double?,
                              sign: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label).font(.callout)
            Spacer()
            if let v = value {
                Text("\(sign)\(Int(v.rounded())) kcal")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: d)
    }

    private func loadInspectedBreakdown() async {
        guard case .deficit = config.source else { return }
        guard let d = inspectedDate else {
            await MainActor.run { deficitBreakdown = nil }
            return
        }
        let target = nearestPoint(to: d)?.date ?? d
        do {
            let loader = DashboardLoader(database: environment.database)
            let b = try await loader.loadDeficitBreakdown(for: target)
            await MainActor.run { deficitBreakdown = b }
        } catch {
            await MainActor.run { deficitBreakdown = nil }
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
        let values = visiblePoints.compactMap { $0.value }
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
        let vis = visiblePoints
        guard !vis.isEmpty else { return "" }
        let first = vis.first?.date ?? Date()
        let last = vis.last?.date ?? Date()
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

        // Bar charts are drawn from a 0 baseline — the domain MUST include 0, otherwise
        // every bar overflows past the visible plot and the chart reads as a solid block.
        // (Line/area charts float freely, so they keep the tight padded domain below.)
        if config.chartStyle == .bar {
            let lo = min(0, mn)
            let hi = max(0, mx)
            let span = max(hi - lo, 1)
            let pad = span * 0.12
            return (lo == 0 ? 0 : lo - pad)...(hi == 0 ? 0 : hi + pad)
        }

        // Single value: pad ±5% (or 1 unit absolute if data is huge) so the dot lands mid-chart.
        if mn == mx {
            let pad = max(abs(mn) * 0.05, 0.5)
            return (mn - pad)...(mx + pad)
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
                // Anchor the scroll window. When the data fills the pane, show the most
                // recent window; when it doesn't, start at the first datum (the window is
                // shrunk to the data span, so everything is visible and stretched anyway).
                let cal = Calendar.current
                let plotted = pts.compactMap { $0.value != nil ? $0.date : nil }
                if let first = plotted.first, let last = plotted.last {
                    let dataDays = cal.dateComponents([.day], from: first, to: last).day ?? 0
                    if dataDays + 1 < period.days {
                        self.scrollPositionX = first
                    } else {
                        self.scrollPositionX = cal.date(byAdding: .day, value: -(period.days - 1), to: last) ?? last
                    }
                }
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
    /// HealthKit identifier whose raw samples should be listed when a day is inspected.
    /// nil for derived/aggregate-only metrics (steps, deficit, …).
    var rawSamplesType: String? = nil

    static let weight = MetricDetailConfig(
        title: "体重",
        unit: "kg",
        source: .tableColumn("body_metrics_daily", "weight_kg", .latest),
        theme: .body,
        chartStyle: .line,
        summary: .latest,
        footnote: "数据来自 Apple 健康 · 每日多次称重取平均；点击某天可查看当天全部记录。",
        format: { String(format: "%.1f", $0) },
        rawSamplesType: "HKQuantityTypeIdentifierBodyMass"
    )

    static let bodyFat = MetricDetailConfig(
        title: "体脂率",
        unit: "%",
        source: .tableColumn("body_metrics_daily", "body_fat_pct", .latest),
        theme: .body,
        chartStyle: .line,
        summary: .latest,
        footnote: "数据来自 Apple 健康 · 每日多次测量取平均；体脂率换算为百分比展示。",
        format: { String(format: "%.1f", $0 * 100) },
        rawSamplesType: "HKQuantityTypeIdentifierBodyFatPercentage"
    )

    static let bmi = MetricDetailConfig(
        title: "BMI",
        unit: nil,
        source: .tableColumn("body_metrics_daily", "bmi", .latest),
        theme: .body,
        chartStyle: .line,
        summary: .latest,
        footnote: "BMI = 体重(kg) / 身高²(m²)。每日多次测量取平均。来自 Apple 健康。",
        format: { String(format: "%.1f", $0) },
        rawSamplesType: "HKQuantityTypeIdentifierBodyMassIndex"
    )

    static let steps = MetricDetailConfig(
        title: "步数",
        unit: "步",
        source: .tableColumn("activity_metrics_daily", "step_count", .sum),
        theme: .activity,
        chartStyle: .bar,
        summary: .total,
        footnote: "Apple 健康每日步数汇总。",
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
        footnote: "按日合计的 meal_records.calories_kcal。",
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
