import SwiftUI
import Charts
import GRDB

struct ActivityDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var summary = ActivityDetailSummary()
    @State private var workouts: [ActivityWorkoutRow] = []
    @State private var energyPoints: [MetricPoint] = []
    @State private var stepPoints: [MetricPoint] = []
    @State private var period: MetricPeriod = .week
    @State private var showingManualEntry = false
    @State private var loadError: String?

    var body: some View {
        List {
            Section("今日消耗") {
                LabeledContent("总消耗", value: kcalLabel(summary.totalBurnedKcal))
                LabeledContent("活动能量", value: kcalLabel(summary.activeEnergyKcal))
                LabeledContent("基础代谢", value: kcalLabel(summary.basalEnergyKcal))
                LabeledContent("饮食摄入", value: kcalLabel(summary.intakeKcal))
                LabeledContent("热量缺口", value: signedKcalLabel(summary.deficitKcal))
            }

            Section("今日活动") {
                LabeledContent("步数", value: summary.steps.map { "\($0) 步" } ?? "—")
                LabeledContent("距离", value: distanceLabel(summary.distanceMeters))
                LabeledContent("锻炼时长", value: minutesLabel(summary.exerciseMinutes))
            }

            Section("趋势") {
                Picker("周期", selection: $period) {
                    ForEach(MetricPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                ActivityMetricBarChart(
                    title: "活动能量",
                    unit: "kcal",
                    points: energyPoints,
                    period: period,
                    emptyText: "该时段暂无活动能量",
                    format: { String(format: "%.0f", $0) }
                )

                ActivityMetricBarChart(
                    title: "步数",
                    unit: "步",
                    points: stepPoints,
                    period: period,
                    emptyText: "该时段暂无步数",
                    format: { String(format: "%.0f", $0) }
                )
            }

            Section {
                if workouts.isEmpty {
                    Text("今天还没有运动记录。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workouts) { row in
                        ActivityWorkoutRowView(row: row)
                    }
                }

                Button {
                    showingManualEntry = true
                } label: {
                    Label("补录今天的活动", systemImage: "plus.circle")
                }
            } header: {
                Text("今日训练")
            } footer: {
                Text("热量缺口使用「基础代谢 + 活动能量 − 饮食摄入」。活动能量会合并 Active Energy 与运动记录里的消耗，并避免同一段训练重复计入。")
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("活动")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingManualEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("补录活动")
            }
        }
        .sheet(isPresented: $showingManualEntry, onDismiss: { Task { await refresh() } }) {
            ManualActivityEntryView()
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: sync.aggregationTick) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: environment.localDataTick) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: period) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let selectedPeriod = period
        do {
            let data = try await environment.database.asyncRead { db -> (ActivityDetailSummary, [ActivityWorkoutRow], [MetricPoint], [MetricPoint]) in
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: Date())
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let startEpoch = Int64(start.timeIntervalSince1970)
                let endEpoch = Int64(end.timeIntervalSince1970)
                let key = DashboardLoader.dateKey.string(from: start)

                var summary = ActivityDetailSummary()
                if let row = try Row.fetchOne(db, sql: """
                    SELECT step_count, active_energy_kcal, basal_energy_kcal,
                           distance_m, exercise_minutes
                    FROM activity_metrics_daily
                    WHERE date = ?
                    """, arguments: [key]) {
                    summary.steps = row["step_count"]
                    summary.activeEnergyKcal = row["active_energy_kcal"]
                    summary.basalEnergyKcal = row["basal_energy_kcal"]
                    summary.distanceMeters = row["distance_m"]
                    summary.exerciseMinutes = row["exercise_minutes"]
                }

                let intake = try Double.fetchOne(db, sql: """
                    SELECT SUM(COALESCE(calories_kcal, 0))
                    FROM meal_records
                    WHERE eaten_at >= ? AND eaten_at < ?
                    """, arguments: [startEpoch, endEpoch]) ?? 0
                summary.intakeKcal = intake > 0 ? intake : nil

                let rows = try ActivityWorkoutRow.fetchToday(db: db, start: startEpoch, end: endEpoch)
                let energy = try Self.trendPoints(
                    db: db,
                    column: "active_energy_kcal",
                    period: selectedPeriod
                )
                let steps = try Self.trendPoints(
                    db: db,
                    column: "step_count",
                    period: selectedPeriod
                )
                return (summary, rows, energy, steps)
            }
            await MainActor.run {
                summary = data.0
                workouts = data.1
                energyPoints = data.2
                stepPoints = data.3
                loadError = nil
            }
        } catch {
            await MainActor.run { loadError = "加载失败：\(error.localizedDescription)" }
            AppLogger.shared.error("Activity detail refresh failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func trendPoints(db: Database, column: String, period: MetricPeriod) throws -> [MetricPoint] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let historyDays = period.historyDays
        let cutoff = calendar.date(byAdding: .day, value: -(historyDays - 1), to: todayStart) ?? todayStart
        let raw = try DashboardLoader.dailyValues(
            db,
            column: column,
            table: "activity_metrics_daily",
            fromKey: DashboardLoader.dateKey.string(from: cutoff),
            toKey: DashboardLoader.dateKey.string(from: todayStart)
        )
        return DashboardLoader.fillAndBucket(raw, period: period, aggregation: .sum, daysOverride: historyDays)
    }

    private func kcalLabel(_ value: Double?) -> String {
        value.map { String(format: "%.0f kcal", $0) } ?? "—"
    }

    private func signedKcalLabel(_ value: Double?) -> String {
        value.map { String(format: "%+.0f kcal", $0) } ?? "—"
    }

    private func distanceLabel(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.2f km", value / 1000)
    }

    private func minutesLabel(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.0f 分钟", value)
    }
}

struct ActivityDetailSummary: Equatable, Sendable {
    var steps: Int?
    var activeEnergyKcal: Double?
    var basalEnergyKcal: Double?
    var distanceMeters: Double?
    var exerciseMinutes: Double?
    var intakeKcal: Double?

    var totalBurnedKcal: Double? {
        let active = activeEnergyKcal ?? 0
        let basal = basalEnergyKcal ?? 0
        let total = active + basal
        return total > 0 ? total : nil
    }

    var deficitKcal: Double? {
        guard let totalBurnedKcal else { return nil }
        return totalBurnedKcal - (intakeKcal ?? 0)
    }
}

struct ActivityWorkoutRow: Identifiable, Hashable, Sendable {
    let sampleUUID: String
    let startAt: Int64
    let endAt: Int64
    let durationSeconds: Double
    let activityLabel: String
    let energyKcal: Double?
    let distanceMeters: Double?
    let sourceLabel: String

    var id: String { sampleUUID }

    static func fetchToday(db: Database, start: Int64, end: Int64) throws -> [ActivityWorkoutRow] {
        let dbRows = try Row.fetchAll(db, sql: """
            SELECT sample_uuid, start_at, end_at, value AS duration,
                   extra_json, source_name, source_origin
            FROM health_samples_raw
            WHERE is_deleted = 0
              AND hk_type = ?
              AND start_at >= ? AND start_at < ?
            ORDER BY start_at DESC
            """, arguments: [ActivityEnergyCalculator.workoutType, start, end])
        return dbRows.map(make(from:))
    }

    static func make(from row: Row) -> ActivityWorkoutRow {
        let extra: [String: Any] = {
            guard let json = row["extra_json"] as String?,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return dict
        }()
        let type = (extra["activityType"] as? Int) ?? 0
        let manualName = ManualActivityKind.displayName(forRawValue: extra["manualActivityKind"] as? String)
        let energy = doubleValue(extra["totalEnergyKcal"])
        let distance = doubleValue(extra["totalDistanceMeters"])
        let origin = SourceAttribution.Origin(rawValue: row["source_origin"] ?? "unknown")?.label ?? "未识别"
        return ActivityWorkoutRow(
            sampleUUID: row["sample_uuid"] ?? "",
            startAt: row["start_at"] ?? 0,
            endAt: row["end_at"] ?? 0,
            durationSeconds: row["duration"] ?? 0,
            activityLabel: manualName ?? WorkoutsView.label(for: type),
            energyKcal: energy,
            distanceMeters: distance,
            sourceLabel: origin
        )
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}

private struct ActivityMetricBarChart: View {
    let title: String
    let unit: String
    let points: [MetricPoint]
    let period: MetricPeriod
    let emptyText: String
    let format: (Double) -> String

    @State private var scrollPositionX: Date = Calendar.current.startOfDay(for: Date())

    private var plotPoints: [(Date, Double)] {
        points.compactMap { point in
            guard let value = point.value else { return nil }
            return (point.date, value)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let maxValue = max(plotPoints.map(\.1).max() ?? 0, 1)
        return 0...(maxValue * 1.15)
    }

    /// Shrink the visible window to the data span when there's less than a full pane of
    /// data, so partial-year (etc.) data stretches to fill instead of cramming.
    private var effectiveVisibleSeconds: TimeInterval {
        guard let first = plotPoints.first?.0, let last = plotPoints.last?.0, last > first else {
            return period.visibleDomainSeconds
        }
        let dataSpan = last.timeIntervalSince(first) + 86_400
        return min(period.visibleDomainSeconds, max(dataSpan, 86_400))
    }

    /// Anchor the scroll window: latest pane when data fills it, else the first datum
    /// (window is shrunk to the data span, so all of it shows stretched).
    private func resetScrollToLatest() {
        let cal = Calendar.current
        guard let first = plotPoints.first?.0, let last = plotPoints.last?.0 else { return }
        let dataDays = cal.dateComponents([.day], from: first, to: last).day ?? 0
        if dataDays + 1 < period.days {
            scrollPositionX = first
        } else {
            scrollPositionX = cal.date(byAdding: .day, value: -(period.days - 1), to: last) ?? last
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if plotPoints.isEmpty {
                CardEmptyState(text: emptyText)
                    .frame(height: 150)
            } else {
                Chart {
                    ForEach(plotPoints, id: \.0) { item in
                        BarMark(
                            x: .value("日期", item.0, unit: .day),
                            y: .value(title, item.1)
                        )
                        .foregroundStyle(CardTheme.activity.gradient)
                        .cornerRadius(3)
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
                            AxisValueLabel { Text(format(v)) }
                                .font(.system(size: 10))
                        }
                    }
                }
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: effectiveVisibleSeconds)
                .chartScrollPosition(x: $scrollPositionX)
                .frame(height: 150)
                .onAppear { resetScrollToLatest() }
                .onChange(of: points) { _, _ in resetScrollToLatest() }
                .onChange(of: period) { _, _ in resetScrollToLatest() }
            }
        }
        .padding(.vertical, 6)
    }

    private var xAxisFormat: Date.FormatStyle {
        switch period {
        case .week:
            return .dateTime.weekday(.narrow)
        case .month:
            return .dateTime.month(.defaultDigits).day()
        case .year:
            return .dateTime.month(.abbreviated)
        }
    }
}

struct ActivityWorkoutRowView: View {
    let row: ActivityWorkoutRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.activityLabel)
                    .font(.body.bold())
                Spacer()
                Text(dateLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(durationLabel)
                if let energy = row.energyKcal {
                    Text(String(format: "%.0f kcal", energy))
                }
                if let distance = row.distanceMeters, distance > 0 {
                    Text(String(format: "%.2f km", distance / 1000))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(row.sourceLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.startAt)))
    }

    private var durationLabel: String {
        let minutes = Int(row.durationSeconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        }
        return "\(minutes) 分钟"
    }
}
