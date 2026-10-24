import SwiftUI

// MARK: - View
//
// HealthBriefManager lives outside this isolated source file (owned by the
// Planner layer) and is expected to be a @MainActor ObservableObject exposing:
//   snapshot: HealthBriefSnapshot?, narrative: BriefNarrative?,
//   isAnalyzing: Bool, analysisStatus: String, trainingPending: Bool,
//   func analyze(manual: Bool) async

/// Health brief card. The parent supplies the card chrome (background, corner
/// radius, outer padding), so this view adds no redundant full background or
/// outer padding of its own.
struct HealthBriefCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var manager: HealthBriefManager

    @State private var isDetailsExpanded: Bool = false
    @State private var presentedInterpretation: Interpretation?
    @State private var regenerateAfterDismiss = false

    private struct Interpretation: Identifiable {
        let id = UUID()
        let snapshot: HealthBriefSnapshot
        let narrative: BriefNarrative
    }

    init(manager: HealthBriefManager) {
        self.manager = manager
    }

    // MARK: Derived state

    private var snapshot: HealthBriefSnapshot? { manager.snapshot }

    /// AI narrative only when it belongs to the current snapshot.
    private var narrative: BriefNarrative? {
        guard let snapshot, let narrative = manager.narrative,
              narrative.snapshot_id == snapshot.id else { return nil }
        return narrative
    }

    private var state: BriefState { narrative?.state ?? snapshot?.defaultState ?? .limited }

    private var stateColor: Color {
        switch state {
        case .limited: return .secondary
        case .baseline: return .blue
        case .steady: return .green
        case .caution: return .orange
        case .mixed: return .purple
        }
    }

    /// Narrative summary is policy-capped at 60 characters; local summary is
    /// capped defensively so the layout stays stable.
    private var summaryText: String {
        let raw = narrative?.summary ?? snapshot?.localSummary ?? HealthBriefRules.limitedSummary
        return Self.truncate(raw, limit: 60)
    }

    private var factIDs: [String] {
        [HealthBriefRules.sleepFactID, HealthBriefRules.hrvFactID, HealthBriefRules.batteryFactID]
    }

    private func fact(_ id: String) -> BriefFact? {
        snapshot?.facts.first { $0.id == id }
    }

    private var sourceText: String {
        let sources = (snapshot?.facts ?? [])
            .filter { factIDs.contains($0.id) }
            .map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sources.first ?? "Garmin Connect"
    }

    private var observedDate: Date? {
        for id in factIDs {
            if let stamp = fact(id)?.observedAt, stamp.isFinite {
                return Date(timeIntervalSince1970: stamp)
            }
        }
        return nil
    }

    private var timeText: String? {
        observedDate.map { Self.timeFormatter.string(from: $0) }
    }

    private var dateText: String? {
        observedDate.map { Self.dateFormatter.string(from: $0) }
    }

    /// Subtitle under the summary: the first fact note, else the observation
    /// time, else nothing.
    private var subtitleText: String? {
        if let note = firstNote { return note }
        return timeText
    }

    private var firstNote: String? {
        for id in factIDs {
            guard let note = fact(id)?.note.trimmingCharacters(in: .whitespacesAndNewlines),
                  !note.isEmpty else { continue }
            return note
        }
        return nil
    }

    private var trainingDays: [BriefTrainingDay] {
        Array((snapshot?.training ?? []).prefix(7))
    }

    private var trainingHasGap: Bool {
        trainingDays.contains { $0.load == nil || $0.incomplete }
    }

    private var mergedLimitations: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in (snapshot?.limitations ?? []) + (narrative?.limitations ?? []) {
            let key = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private var detailFactors: [BriefFactor] {
        Array((narrative?.factors ?? []).prefix(3))
    }

    // MARK: Formatting helpers

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func numeric(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func displayValue(_ fact: BriefFact?) -> String {
        guard let fact, let value = fact.value, value.isFinite else { return "—" }
        return Self.numeric(value)
    }

    private func subtitle(for id: String) -> String? {
        if fact(id)?.value == nil { return "等待更新" }
        if id == "battery", let time = fact(id)?.observedAt {
            return Self.timeFormatter.string(from: Date(timeIntervalSince1970: time)) + " 分段观测"
        }
        if id == "hrv" { return snapshot?.defaultState == .baseline ? "基线建立中" : "夜间平均" }
        return fact(id)?.value == nil ? "等待同步" : "昨晚 · 醒来日期"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    private func dayLabel(for day: BriefTrainingDay) -> String {
        let text = day.date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "--/--" }
        guard let date = Self.isoDayFormatter.date(from: text) else { return text }
        return Self.dayLabelFormatter.string(from: date)
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func barHeight(for day: BriefTrainingDay, maxLoad: Double) -> CGFloat {
        // A nil load is an uncollected gap and is drawn as a dashed outline by
        // BriefTrainingBar, never as a zero-height "rest" bar.
        guard let load = day.load, load.isFinite, load > 0 else { return 0 }
        guard maxLoad > 0 else { return 1 }
        let scaled = (CGFloat(load) / CGFloat(maxLoad)) * Self.maxBarHeight
        return max(1, min(Self.maxBarHeight, scaled))
    }

    private static let maxBarHeight: CGFloat = 24
    private static let chartHeight: CGFloat = 24

    private var maxTrainingLoad: Double {
        let loads = trainingDays.compactMap { $0.load }.filter { $0.isFinite && $0 > 0 }
        return loads.max() ?? 0
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            stateRow
            summaryBlock
            factTiles
            trainingSection
            details
            analyzeFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $presentedInterpretation, onDismiss: {
            guard regenerateAfterDismiss else { return }
            regenerateAfterDismiss = false
            Task { await generateAndPresent() }
        }) { item in
            BriefInterpretationSheet(snapshot: item.snapshot, narrative: item.narrative) {
                regenerateAfterDismiss = true
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func presentCurrentInterpretation() {
        guard let snapshot, let narrative else { return }
        presentedInterpretation = Interpretation(snapshot: snapshot, narrative: narrative)
    }

    @MainActor private func generateAndPresent() async {
        guard await manager.analyze(manual: true) else { return }
        presentCurrentInterpretation()
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { titleLabel; Spacer(); channelLabel }
            VStack(alignment: .leading, spacing: 4) { titleLabel; channelLabel }
        }
    }
    private var titleLabel: some View {
            Text("健康速报")
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("health-brief-title")
    }
    private var channelLabel: some View {
        Text(narrative != nil ? "AI辅助解读" : "本地汇总")
            .font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    // MARK: State

    private var stateRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: state.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(stateColor)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(stateColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("health-brief-state")
    }

    // MARK: Summary

    @ViewBuilder private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    // MARK: Fact tiles

    private var isAccessibilityLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    private var factTiles: some View {
        Group {
            if isAccessibilityLarge {
                VStack(alignment: .leading, spacing: 10) { factTileColumn }
            } else {
                HStack(alignment: .top, spacing: 10) { factTileRow }
            }
        }
    }

    private var factTileRow: some View {
        Group {
            sleepTile
                .frame(maxWidth: .infinity, alignment: .leading)
            hrvTile
                .frame(maxWidth: .infinity, alignment: .leading)
            batteryTile
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var factTileColumn: some View {
        Group {
            sleepTile
            hrvTile
            batteryTile
        }
    }

    private var sleepTile: some View {
        BriefMetricTile(
            title: "睡眠",
            value: displayValue(fact(HealthBriefRules.sleepFactID)),
            unit: fact(HealthBriefRules.sleepFactID)?.unit ?? "",
            subtitle: subtitle(for: HealthBriefRules.sleepFactID),
            identifier: "health-brief-sleep",
            accessibilityLabel: accessibilityLabel(
                metric: "睡眠",
                factID: HealthBriefRules.sleepFactID,
                fallbackUnit: ""
            ),
            ringFraction: ringFraction(for: HealthBriefRules.sleepFactID),
            ringColor: .purple,
            showsSegmentedGauge: false
        )
    }

    private var hrvTile: some View {
        BriefMetricTile(
            title: "夜间 HRV",
            value: displayValue(fact(HealthBriefRules.hrvFactID)),
            unit: fact(HealthBriefRules.hrvFactID)?.unit ?? "ms",
            subtitle: subtitle(for: HealthBriefRules.hrvFactID),
            identifier: "health-brief-hrv",
            accessibilityLabel: accessibilityLabel(
                metric: "夜间 HRV",
                factID: HealthBriefRules.hrvFactID,
                fallbackUnit: "ms"
            ),
            ringFraction: nil,
            ringColor: .cyan,
            showsSegmentedGauge: false
        )
    }

    private var batteryTile: some View {
        BriefMetricTile(
            title: "Body Battery",
            value: displayValue(fact(HealthBriefRules.batteryFactID)),
            unit: fact(HealthBriefRules.batteryFactID)?.unit ?? "",
            subtitle: subtitle(for: HealthBriefRules.batteryFactID),
            identifier: "health-brief-battery",
            accessibilityLabel: accessibilityLabel(
                metric: "Body Battery",
                factID: HealthBriefRules.batteryFactID,
                fallbackUnit: ""
            ),
            ringFraction: nil,
            ringColor: .orange,
            showsSegmentedGauge: true
        )
    }

    private func accessibilityLabel(metric: String, factID: String, fallbackUnit: String) -> String {
        let fact = fact(factID)
        let value = displayValue(fact)
        let unit = fact?.unit ?? fallbackUnit
        var parts = [metric, value]
        if !unit.isEmpty { parts.append(unit) }
        if let note = fact?.note.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(note)
        } else if let timeText {
            parts.append(timeText)
        }
        return parts.joined(separator: "，")
    }

    /// Sleep ring is normalized on a 0...100 scale.
    private func ringFraction(for id: String) -> CGFloat? {
        guard let value = fact(id)?.value, value.isFinite else { return nil }
        return min(1, max(0, CGFloat(value) / 100))
    }

    // MARK: Training

    @ViewBuilder private var trainingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("过去七个完整日 · 训练负荷")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                if manager.trainingPending {
                    Text("训练背景计算中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if trainingDays.isEmpty {
                Text("暂无训练记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                trainingChart
                trainingDayLabels

            }
        }
    }

    private var trainingChart: some View {
        GeometryReader { proxy in
            let count = max(trainingDays.count, 1)
            let spacing: CGFloat = 6
            let width = max(0, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(trainingDays.enumerated()), id: \.offset) { _, day in
                    BriefTrainingBar(
                        height: barHeight(for: day, maxLoad: maxTrainingLoad),
                        isGap: day.load == nil,
                        width: width
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trainingChartLabel)
    }

    private var trainingChartLabel: String {
        let maxLoad = maxTrainingLoad
        let maxLoadText = maxLoad > 0 ? Self.numeric(maxLoad) : "暂无"
        let lines = trainingDays.map { day in
            let loadText = day.load.flatMap { $0.isFinite ? Self.numeric($0) : nil } ?? "未采集"
            let minuteText = day.minutes.flatMap { $0.isFinite ? Self.numeric($0) : nil } ?? "未采集"
            let gapText = day.incomplete ? "，记录不完整" : ""
            return "\(dayLabel(for: day))：负荷 \(loadText)，时长 \(minuteText) 分钟\(gapText)"
        }
        return "过去 7 个完整日训练负荷，最高负荷 \(maxLoadText)。" + lines.joined(separator: "；")
    }

    private var trainingDayLabels: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(trainingDays.enumerated()), id: \.offset) { _, day in
                Text(dayLabel(for: day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Details

    private var details: some View {
        DisclosureGroup(isExpanded: $isDetailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !detailFactors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(detailFactors.enumerated()), id: \.offset) { _, factor in
                            factorRow(factor)
                        }
                    }
                }
                ForEach(Array((snapshot?.facts ?? []).enumerated()), id: \.offset) { _, item in
                    factDetailRow(item)
                }
                ForEach([GarminMetric.sleep, .hrv, .bodyBattery], id: \.self) { metric in
                    NavigationLink(metric.title + "详情") { GarminMetricDetailView(manager: environment.garmin, metric: metric) }
                        .font(.footnote).frame(minHeight: 44)
                }
                Text("虚线表示负荷缺测，不表示休息。无个人基线时不判断 HRV 高低。生活参考，非佳明训练准备评分。")
                    .font(.caption).foregroundStyle(.secondary)
                if !mergedLimitations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("局限")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(mergedLimitations.enumerated()), id: \.offset) { _, limitation in
                            Label(limitation, systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("依据与来源")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .tint(.secondary)
    }

    private func factorRow(_ factor: BriefFactor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(factor.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(factorEvidenceText(factor))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factorEvidenceText(_ factor: BriefFactor) -> String {
        let parts = factor.fact_ids.compactMap { id -> String? in
            guard let item = fact(id) else { return nil }
            let value = item.value.flatMap { $0.isFinite ? Self.numeric($0) : nil } ?? "—"
            let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            return unit.isEmpty ? "\(item.title) \(value)" : "\(item.title) \(value) \(unit)"
        }
        return parts.joined(separator: " · ")
    }

    private func factDetailRow(_ item: BriefFact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(item.title)：\(displayValue(item))\(item.unit.isEmpty ? "" : " \(item.unit)")")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(detailMetaText(item))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailMetaText(_ item: BriefFact) -> String {
        var parts: [String] = []
        if !item.date.isEmpty { parts.append(item.date) }
        if let stamp = item.observedAt { parts.append(Self.timeFormatter.string(from: Date(timeIntervalSince1970: stamp))) }
        if !item.source.isEmpty { parts.append(item.source) }
        let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    // MARK: Analyze footer

    private var analyzeFooter: some View {
        Group {
            if isAccessibilityLarge {
                VStack(alignment: .leading, spacing: 6) { analysisLabel; analyzeButton }
            } else {
                HStack(spacing: 8) { analysisLabel; Spacer(minLength: 0); analyzeButton }
            }
        }
    }
    private var analysisLabel: some View {
        Text(manager.analysisStatus).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var analyzeButton: some View {
        Button {
            if narrative != nil { presentCurrentInterpretation() }
            else { Task { await generateAndPresent() } }
        } label: {
            Text(manager.isAnalyzing ? "解读中" : (narrative != nil ? "查看AI解读" : "AI解读"))
        }.buttonStyle(.bordered).disabled(manager.isAnalyzing)
            .accessibilityIdentifier("health-brief-analyze")
    }

    private var disclaimer: some View {
        Text("生活参考 · 非佳明训练准备评分")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tile

private struct BriefMetricTile: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    let unit: String
    let subtitle: String?
    let identifier: String
    let accessibilityLabel: String
    let ringFraction: CGFloat?
    let ringColor: Color
    let showsSegmentedGauge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let ringFraction, !typeSize.isAccessibilitySize {
                ZStack {
                    BriefSleepRing(fraction: ringFraction, color: ringColor)
                    Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(ringColor)
                }.frame(width: 52, height: 52)
            } else if showsSegmentedGauge {
                BriefSegmentedGauge(valueText: value, color: ringColor)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.title2.bold()).fontDesign(.rounded).foregroundStyle(ringColor)
                    if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }
}

private struct BriefSleepRing: View {
    let fraction: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

private struct BriefSegmentedGauge: View {
    let valueText: String
    let color: Color

    private static let segmentCount = 10

    private var filled: Int {
        let value = Double(valueText) ?? -1
        guard value.isFinite, value >= 0 else { return 0 }
        return Int(min(1, max(0, value / 100)) * Double(Self.segmentCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(valueText)
                    .font(.title3.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(color)
                Text("/100")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                ForEach(0 ..< Self.segmentCount, id: \.self) { index in
                    Capsule()
                        .fill(index < filled ? color : color.opacity(0.2))
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Training bar

private struct BriefTrainingBar: View {
    let height: CGFloat
    let isGap: Bool
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isGap ? Color.clear : Color.accentColor.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        isGap ? Color.secondary.opacity(0.7) : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
            .frame(width: max(4, width), height: isGap ? 24 : max(1, height))
            .frame(maxWidth: .infinity, alignment: .bottom)
            .accessibilityHidden(true)
    }
}
