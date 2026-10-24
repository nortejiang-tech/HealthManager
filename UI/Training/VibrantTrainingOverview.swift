import SwiftUI

/// Vibrant card presentation of the local training snapshot.
///
/// The parent owns the surrounding `ScrollView` / `NavigationStack`. This view
/// only renders already-computed snapshot values: it never queries HealthKit,
/// persists anything, or performs its own fitness arithmetic beyond windowing
/// the supplied daily buckets.
struct VibrantTrainingOverview: View {
    let snapshot: TrainingSnapshot
    let isStale: Bool
    let onTrends: () -> Void
    let onParameters: () -> Void
    let onMethod: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isReadinessExpanded = false

    private static let windowLength = 7

    // MARK: - Derived window (pure presentation windowing of supplied data)

    /// The last seven complete-day buckets: today's partial bucket is dropped.
    private var windowDays: [TrainingDay] { Array(snapshot.days.dropLast().suffix(Self.windowLength)) }

    /// Exclusive upper bound: start of the day the snapshot was calculated on.
    private var windowUpperBound: Date { Calendar.current.startOfDay(for: snapshot.calculatedAt) }

    private var windowLowerBound: Date {
        Calendar.current.date(byAdding: .day, value: -Self.windowLength, to: windowUpperBound)
            ?? snapshot.calculatedAt
    }

    /// Observed sessions whose start falls inside the seven-day window.
    private var windowSessions: [TrainingSession] {
        snapshot.sessions.filter { $0.start >= windowLowerBound && $0.start < windowUpperBound }
    }

    private var runCount: Int { windowSessions.filter(\.isRun).count }

    private var totalRunMinutes: Double { windowDays.reduce(0) { $0 + $1.runMinutes } }

    private var knownRunKm: Double {
        windowSessions.compactMap { $0.isRun ? $0.distanceKm : nil }.reduce(0, +)
    }

    private var hasMissingDistance: Bool {
        windowDays.reduce(0) { $0 + $1.missingDistanceCount } > 0
    }

    private var miniBarValues: [Double?] { windowDays.map { $0.runMinutes } }

    private var vo2Point: TrainingMetricValue? { snapshot.series(for: .vo2).last }

    private var sleepPoint: TrainingMetricValue? { snapshot.series(for: .mainSleep).last }

    private var latestSession: TrainingSession? { snapshot.sessions.first }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            volumeHero
            capabilityGrid
            latestSessionCard
            workoutsLink
            actionButtons
            readinessDisclosure
        }
        .font(.system(.body, design: .rounded))
    }

    // MARK: - Volume hero

    private var volumeHero: some View {
        NavigationLink {
            TrainingMetricDetail(metric: .runMinutes)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("近7个完整日 · 已记录跑步")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer(minLength: 8)
                    if isStale {
                        Text("上次计算 · \(Self.dateFormatter.string(from: snapshot.calculatedAt))")
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.white.opacity(0.16))
                            )
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(runCount == 0 ? "暂无记录" : Self.minutesText(totalRunMinutes))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(runCount == 0 ? "" : "分钟")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("近7个完整日跑步 \(Int(totalRunMinutes.rounded())) 分钟")

                HMMiniBars(
                    values: miniBarValues,
                    accent: .jade,
                    accessibilitySummary: barsSummary
                ).environment(\.colorScheme, .dark)

                HStack(alignment: .top, spacing: 16) {
                    heroFact(
                        title: "已知距离",
                        value: TrainingText.number(knownRunKmValue, unit: "km")
                    )
                    heroFact(
                        title: "跑步次数",
                        value: runCount == 0 ? "暂无记录" : "\(runCount) 次"
                    )
                    Spacer(minLength: 0)
                }

                if hasMissingDistance {
                    Label("部分距离缺失", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.black.opacity(0.26))
                        )
                }

                Text(dateWindowCaption)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.20, blue: 0.145))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("training-volume-card")
    }

    private var knownRunKmValue: Double? {
        windowSessions.contains { $0.isRun && $0.distanceKm != nil } ? knownRunKm : nil
    }

    private func heroFact(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var barsSummary: String {
        let observed = miniBarValues.compactMap { $0 }.filter { $0 > 0 }.count
        if observed == 0 {
            return "近7个完整日暂无跑步记录"
        }
        return "近7个完整日共 \(Int(totalRunMinutes.rounded())) 分钟，\(runCount) 次跑步，图形为每日分钟数"
    }

    private var dateWindowCaption: String {
        let formatter = Self.windowDayFormatter
        let lower = formatter.string(from: windowLowerBound)
        let upper = formatter.string(
            from: Calendar.current.date(byAdding: .day, value: -1, to: windowUpperBound)
                ?? windowUpperBound
        )
        return "\(lower) – \(upper) · 共 \(windowDays.count) 天"
    }

    // MARK: - Capability grid

    private var capabilityGrid: some View {
        let columns: [GridItem] = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12, alignment: .top)]
            : [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]

        return LazyVGrid(columns: columns, spacing: 12) {
            capabilityTile(
                identifier: "training-capability-card",
                title: "心肺能力",
                symbol: "heart.text.square.fill",
                accent: .coral,
                point: vo2Point,
                unit: "ml/kg/min",
                sourceCaption: "设备估计",
                metric: .vo2
            )
            capabilityTile(
                identifier: "training-sleep-card",
                title: "主睡眠",
                symbol: "moon.stars.fill",
                accent: .lavender,
                point: sleepPoint,
                unit: "小时",
                sourceCaption: nil,
                metric: .mainSleep
            )
        }
    }

    @ViewBuilder
    private func capabilityTile(
        identifier: String,
        title: String,
        symbol: String,
        accent: HMAccent,
        point: TrainingMetricValue?,
        unit: String,
        sourceCaption: String?,
        metric: TrainingMetric
    ) -> some View {
        NavigationLink {
            TrainingMetricDetail(metric: metric)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(accent.color)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(point.map { Self.valueText($0.value) } ?? "—")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(unit)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if point != nil {
                    TrainingMetricChart(metric: metric, points: snapshot.series(for: metric), compact: true)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("暂无数据")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Text(tileCaption(point: point, sourceCaption: sourceCaption))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(accent.soft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(accent.color.opacity(0.22), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tileAccessibilityTitle(title: title, point: point, unit: unit))
        .accessibilityIdentifier(identifier)
    }

    private func tileCaption(point: TrainingMetricValue?, sourceCaption: String?) -> String {
        guard let point else { return sourceCaption ?? "暂无数据" }
        let date = Self.dateFormatter.string(from: point.date)
        if let sourceCaption {
            return [sourceCaption, point.sourceName, date].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [point.sourceName, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func tileAccessibilityTitle(title: String, point: TrainingMetricValue?, unit: String) -> String {
        guard let point else { return "\(title)，暂无数据" }
        return "\(title)，\(Self.valueText(point.value)) \(unit)"
    }

    // MARK: - Latest session

    @ViewBuilder
    private var latestSessionCard: some View {
        if let session = latestSession {
            NavigationLink {
                TrainingSessionDetail(session: session)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "figure.run")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(HMAccent.jade.color)
                            .accessibilityHidden(true)
                        Text(session.sourceName.isEmpty ? session.source : session.sourceName)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(Self.dateFormatter.string(from: session.start))
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(WorkoutsView.label(for: session.activityType))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TrainingText.number(session.distanceKm, unit: "km"))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(Int(session.minutes.rounded())) 分钟")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(TrainingText.pace(session.paceSecondsPerKm))
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .hmCard(accent: .jade)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("training-session-\(session.id)")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("暂无运动记录")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .hmCard(accent: .sky)
        }
    }

    private var workoutsLink: some View {
        NavigationLink {
            WorkoutsView()
        } label: {
            HStack {
                Text("查看全部运动与补录")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HMAccent.jade.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(HMAccent.jade.color.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("training-workouts")
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton(title: "趋势", symbol: "chart.line.uptrend.xyaxis", action: onTrends)
                .accessibilityIdentifier("training-open-trends")
            actionButton(title: "全部参数", symbol: "slider.horizontal.3", action: onParameters)
                .accessibilityIdentifier("training-all-parameters")
        }
    }

    private func actionButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(HMAccent.jade.soft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(HMAccent.jade.color.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Experimental readiness

    private var readinessDisclosure: some View {
        DisclosureGroup("恢复准备度 · 实验", isExpanded: $isReadinessExpanded) {
            TrainingOverviewReadiness(snapshot: snapshot, isStale: isStale, onMethod: onMethod)
                .padding(.top, 6)
        }
        .font(.system(.subheadline, design: .rounded, weight: .semibold))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(HMAccent.sky.soft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(HMAccent.sky.color.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Formatting helpers

    private static func valueText(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return valueFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private static func minutesText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return minuteFormatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }

    // MARK: - Formatters

    private static let valueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let minuteFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let windowDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
