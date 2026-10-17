import SwiftUI
import Charts

struct TrainingWindowPicker: View {
    @Binding var window: Int
    var body: some View {
        Picker("趋势窗口", selection: $window) {
            Text("7天").tag(7); Text("4周").tag(28); Text("8周").tag(56)
        }.pickerStyle(.segmented).accessibilityIdentifier("training-window")
    }
}

struct TrainingReadinessChart: View {
    let points: [TrainingReadinessPoint]
    var compact = false
    @State private var selection: Date?
    private var selected: TrainingReadinessPoint? {
        guard let selection else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(points) { point in
                if let range = point.assessment.referenceRange {
                    RectangleMark(xStart: .value("开始", point.date.addingTimeInterval(-3 * 3600)),
                        xEnd: .value("结束", point.date.addingTimeInterval(3 * 3600)),
                        yStart: .value("个人P25", range.lowerBound), yEnd: .value("个人P75", range.upperBound))
                        .foregroundStyle(HMColors.comparison.opacity(0.12))
                }
                if let score = point.assessment.score {
                    PointMark(x: .value("睡后评估", point.date), y: .value("准备度", score))
                        .foregroundStyle(HMColors.estimate).symbolSize(compact ? 20 : 35)
                } else if let range = point.assessment.possibleRange {
                    RuleMark(x: .value("睡后评估", point.date), yStart: .value("可能下界", range.lowerBound),
                        yEnd: .value("可能上界", range.upperBound))
                        .foregroundStyle(HMColors.estimate).lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
                }
            }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXSelection(value: $selection)
            .frame(height: compact ? 85 : 200)
            .accessibilityLabel("恢复准备度，0至100分；圆点是单点，竖线是可能范围，空白为未评估")
            if !compact {
                Text("圆点：单点 · 竖线：负荷缺失范围 · 浅色：个人P25–P75")
                    .font(.caption).foregroundStyle(.secondary)
                if let selected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(TrainingText.time(selected.assessment.observedAt ?? selected.date)) · \(TrainingText.readiness(selected.assessment))")
                            .font(.headline)
                        Text(selected.assessment.source.isEmpty ? "无主睡眠来源" : "来源：\(selected.assessment.source)")
                        ForEach(selected.assessment.missingReasons, id: \.self) { Text($0) }
                    }.font(.caption).accessibilityElement(children: .combine)
                    DisclosureGroup("这次评估的输入与基线") {
                        ForEach(selected.assessment.factors) { factor in
                            VStack(alignment: .leading, spacing: 4) {
                                TrainingStatRow(label: factor.title, value: factor.value)
                                Text(factor.detail).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }.font(.subheadline)
                    HStack {
                        Button("上一天") { move(-1) }.disabled(selected.id == points.first?.id)
                        Spacer()
                        Button("下一天") { move(1) }.disabled(selected.id == points.last?.id)
                    }.font(.subheadline)
                }
                Text("\(points.filter { $0.assessment.score != nil }.count)个单点，\(points.filter { $0.assessment.possibleRange != nil }.count)个范围；其余日期未评估。缺测不补值、不连线。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: points.first?.id) { _, _ in selection = nil }
    }
    private var domain: ClosedRange<Date> {
        let first = points.first?.date ?? Date(), last = points.last?.date ?? Date()
        let start = Calendar.current.startOfDay(for: first)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: last))!
        return start...max(end, start.addingTimeInterval(86400))
    }
    private func move(_ offset: Int) {
        guard let selected, let index = points.firstIndex(where: { $0.id == selected.id }) else { return }
        selection = points[min(max(0, index + offset), points.count - 1)].date
    }
}

struct TrainingMetricChart: View {
    let metric: TrainingMetric
    let points: [TrainingMetricValue]
    var compact = false
    @State private var selection: Date?
    @State private var inspectedID: String?
    private var sources: [String] { Array(Set(points.map(\.source))).sorted() }
    private var colors: [Color] { [HMColors.confirmed, HMColors.estimate, HMColors.comparison, .purple, .orange, .cyan] }
    private var selected: TrainingMetricValue? {
        if let inspectedID, let point = points.first(where: { $0.id == inspectedID }) { return point }
        guard let selection else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if points.isEmpty {
                TrainingChartEmpty(text: "此期间暂无记录")
            } else {
                Chart(points) { point in
                    if metric.isBar {
                        BarMark(x: .value("日期", point.date, unit: .day), y: .value(metric.unit, point.value))
                            .foregroundStyle(HMColors.comparison).cornerRadius(2)
                    } else {
                        PointMark(x: .value("测量时间", point.date), y: .value(metric.unit, point.value))
                            .foregroundStyle(by: .value("来源标识", point.source))
                            .symbolSize(compact ? 16 : 28)
                    }
                }
                .chartForegroundStyleScale(domain: sources, range: sources.indices.map { colors[$0 % colors.count] })
                .chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: metric.isBar))
                .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
                }
            }
                .chartXSelection(value: $selection)
                .frame(height: compact ? 85 : 200)
                .accessibilityLabel("\(metric.title)，单位\(metric.unit)，\(points.count)个观测，不补缺测")
                if !compact, sources.count > 1 {
                    ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(colors[index % colors.count]).frame(width: 8, height: 8).padding(.top, 3)
                            Text(points.first(where: { $0.source == source })?.sourceName ?? source)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !compact, let selected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(TrainingText.observationTime(selected)) · \(TrainingText.metricValue(selected.value, metric))").font(.headline)
                        Text("来源：\(selected.sourceName)").font(.caption).foregroundStyle(.secondary)
                        if let count = selected.sampleCount { Text("这一时段\(count)个原始样本").font(.caption).foregroundStyle(.secondary) }
                    }.accessibilityElement(children: .combine)
                    HStack {
                        Button("上一条") { move(-1) }.disabled(selected.id == points.first?.id)
                        Spacer()
                        Button("下一条") { move(1) }.disabled(selected.id == points.last?.id)
                    }.font(.subheadline)
                }
            }
        }.onChange(of: points.first?.id) { _, _ in selection = nil; inspectedID = nil }
        .onChange(of: selection) { _, _ in inspectedID = nil }
    }
    private func move(_ offset: Int) {
        guard let selected, let index = points.firstIndex(where: { $0.id == selected.id }) else { return }
        inspectedID = points[min(max(0, index + offset), points.count - 1)].id
    }
}

struct TrainingMetricContent: View {
    let snapshot: TrainingSnapshot
    let metric: TrainingMetric
    let window: Int
    private var points: [TrainingMetricValue] {
        guard let begin = snapshot.recentDays(window).first?.date else { return [] }
        return snapshot.series(for: metric).filter { $0.date >= begin }
    }
    var body: some View {
        TrainingPanel(title: metric.title, icon: "chart.xyaxis.line") {
            if metric == .readiness {
                Text(TrainingText.readiness(snapshot.readiness)).font(.title.weight(.semibold))
                Text("最近一次睡后评估 · \(TrainingText.time(snapshot.readiness.observedAt))").font(.caption)
                TrainingReadinessChart(points: Array(snapshot.readinessHistory.suffix(window)))
                Text("\(TrainingReadiness.version)\n回溯重算于 \(TrainingText.time(snapshot.calculatedAt))。延迟入库可能修正历史。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let latest = points.last {
                    Text(TrainingText.metricValue(latest.value, metric)).font(.title.weight(.semibold)).monospacedDigit()
                    Text("最近观测：\(TrainingText.observationTime(latest))").font(.caption).foregroundStyle(.secondary)
                }
                Text(metric.unit).font(.caption.weight(.semibold))
                TrainingMetricChart(metric: metric, points: points)
                Text(TrainingText.change(points, metric: metric)).font(.subheadline)
                Text("\(points.count)个观测 · \(Set(points.map(\.source)).count)个序列组；原始来源分别标色，日汇总可能包含多个来源。")
                    .font(.caption).foregroundStyle(.secondary)
                if metric == .load {
                    Text("\(snapshot.recentDays(window).map(\.missingLoadCount).reduce(0, +))次运动负荷缺失；柱状图仅含可计算部分。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metric == .runDistance {
                    Text("\(snapshot.recentDays(window).map(\.missingDistanceCount).reduce(0, +))次跑步距离缺失。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metric == .mainSleep, let night = snapshot.latestNight {
                    TrainingStatRow(label: "最近主睡眠时段", value: "\(TrainingText.time(night.start)) – \(TrainingText.time(night.end))")
                }
            }
            Text(metric.definition).font(.footnote).foregroundStyle(.secondary)
        }
        if [.runPace, .runHeart].contains(metric) { TrainingRunComparisonPanel(snapshot: snapshot) }
        if [.runPace, .runHeart, .recovery60, .recovery120, .load].contains(metric) {
            TrainingPanel(title: "对应运动记录", icon: "figure.run") {
                let ids = Set(points.map(\.id))
                ForEach(snapshot.sessions.filter { ids.contains($0.id) }.prefix(12)) { session in
                    NavigationLink { TrainingSessionDetail(session: session) } label: {
                        Text("\(TrainingText.time(session.start)) · \(WorkoutsView.label(for: session.activityType))")
                    }
                }
                NavigationLink("全部运动与补录", destination: WorkoutsView())
            }
        }
    }
}

struct TrainingTrendsPanel: View {
    let snapshot: TrainingSnapshot
    @State private var group = "状态"
    @State private var metric: TrainingMetric = .readiness
    @State private var window = 28
    private var metrics: [TrainingMetric] {
        switch group {
        case "能力": return [.vo2, .runPace, .runHeart]
        case "活动量": return [.runMinutes, .runDistance, .steps, .distance, .activeEnergy, .load]
        default: return [.readiness, .nightHRV, .sleepHeart, .mainSleep, .restingHeart]
        }
    }
    var body: some View {
        Picker("趋势分类", selection: $group) {
            Text("状态").tag("状态"); Text("能力").tag("能力"); Text("活动量").tag("活动量")
        }.pickerStyle(.segmented)
        Picker("指标", selection: $metric) { ForEach(metrics) { Text($0.title).tag($0) } }
            .accessibilityIdentifier("training-trend-metric")
        TrainingWindowPicker(window: $window)
        TrainingMetricContent(snapshot: snapshot, metric: metric, window: window)
            .id(metric)
            .onChange(of: group) { _, _ in metric = metrics[0] }
    }
}
