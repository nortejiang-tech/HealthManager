import SwiftUI

enum TodayDestination: Hashable {
    case diet
    case medication
    case trends
}

private enum TodayInternalDestination: Hashable {
    case alerts
    case dataQuality
    case sources
}

enum TodayScreenState: Equatable {
    case loading
    case loaded(TodayEvidencePresentation)
    case failed(String)
}

struct TodayView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    @State private var state: TodayScreenState = .loading
    @State private var navigationPath: [TodayInternalDestination] = []
    @State private var generation: UInt64 = 0
    @State private var inFlightLoad: Task<TodayEvidenceSnapshot, Error>?

    let onSelectDestination: (TodayDestination) -> Void

    init(onSelectDestination: @escaping (TodayDestination) -> Void = { _ in }) {
        self.onSelectDestination = onSelectDestination
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TodayScreenContent(
                state: state,
                onQualityTap: openQualityDestination,
                onSummaryTap: { onSelectDestination(.trends) },
                onTimelineTap: openTimelineDestination,
                onRecordMealTap: { onSelectDestination(.diet) },
                onMedicationTap: { onSelectDestination(.medication) },
                onSourcesTap: { navigationPath.append(.sources) },
                onRetryTap: {
                    Task { await reload(showInitialLoading: true) }
                }
            )
            .refreshable {
                await reload()
            }
            .navigationDestination(for: TodayInternalDestination.self) { destination in
                switch destination {
                case .alerts:
                    AlertsView()
                case .dataQuality:
                    DataQualityDetailView()
                case .sources:
                    SourcesView()
                }
            }
        }
        .task {
            await reload(showInitialLoading: true)
        }
        .onChange(of: environment.localDataTick) { _, _ in
            Task { await reload() }
        }
        .onChange(of: sync.aggregationTick) { _, _ in
            Task { await reload() }
        }
        .onChange(of: sync.lastResult) { _, _ in
            Task { await reload() }
        }
        .onDisappear {
            generation &+= 1
            inFlightLoad?.cancel()
            inFlightLoad = nil
        }
    }

    @MainActor
    private func reload(showInitialLoading: Bool = false) async {
        generation &+= 1
        let requestGeneration = generation

        inFlightLoad?.cancel()
        if showInitialLoading {
            if case .loaded = state {
                // Preserve useful content while a subsequent request is in flight.
            } else {
                state = .loading
            }
        }

        let database = environment.database
        let requestCalendar = calendar
        let requestLocale = TodayEvidencePresentation.resolvedInterfaceLocale(
            environmentLocale: locale
        )
        let request = Task<TodayEvidenceSnapshot, Error> {
            try Task.checkCancellation()
            return try await TodayEvidenceLoader(database: database).load(
                forLocalDay: Date(),
                calendar: requestCalendar
            )
        }
        inFlightLoad = request

        do {
            let snapshot = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard requestGeneration == generation,
                  !Task.isCancelled,
                  !request.isCancelled
            else {
                return
            }
            state = .loaded(
                TodayEvidencePresentation(
                    calendar: requestCalendar,
                    locale: requestLocale,
                    snapshot: snapshot
                )
            )
            inFlightLoad = nil
        } catch is CancellationError {
            if requestGeneration == generation {
                inFlightLoad = nil
            }
        } catch {
            guard requestGeneration == generation,
                  !Task.isCancelled,
                  !request.isCancelled
            else {
                return
            }
            state = .failed("今日数据暂时无法读取，请重试。")
            inFlightLoad = nil
        }
    }

    private func openQualityDestination() {
        guard case let .loaded(presentation) = state else { return }
        navigationPath.append(
            presentation.qualityStyle == .hasAlerts ? .alerts : .dataQuality
        )
    }

    private func openTimelineDestination(_ kind: TodayEvidencePresentation.TimelineRow.Kind) {
        switch kind {
        case .meal:
            onSelectDestination(.diet)
        case .medication:
            onSelectDestination(.medication)
        }
    }
}

struct TodayScreenContent: View {
    let state: TodayScreenState
    let onQualityTap: () -> Void
    let onSummaryTap: () -> Void
    let onTimelineTap: (TodayEvidencePresentation.TimelineRow.Kind) -> Void
    let onRecordMealTap: () -> Void
    let onMedicationTap: () -> Void
    let onSourcesTap: () -> Void
    let onRetryTap: () -> Void

    init(
        state: TodayScreenState,
        onQualityTap: @escaping () -> Void = {},
        onSummaryTap: @escaping () -> Void = {},
        onTimelineTap: @escaping (TodayEvidencePresentation.TimelineRow.Kind) -> Void = { _ in },
        onRecordMealTap: @escaping () -> Void = {},
        onMedicationTap: @escaping () -> Void = {},
        onSourcesTap: @escaping () -> Void = {},
        onRetryTap: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onQualityTap = onQualityTap
        self.onSummaryTap = onSummaryTap
        self.onTimelineTap = onTimelineTap
        self.onRecordMealTap = onRecordMealTap
        self.onMedicationTap = onMedicationTap
        self.onSourcesTap = onSourcesTap
        self.onRetryTap = onRetryTap
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            switch state {
            case .loading:
                TodayLoadingView()
            case let .failed(message):
                TodayFailureView(message: message, onRetryTap: onRetryTap)
            case let .loaded(presentation):
                TodayLoadedContent(
                    presentation: presentation,
                    onQualityTap: onQualityTap,
                    onSummaryTap: onSummaryTap,
                    onTimelineTap: onTimelineTap,
                    onRecordMealTap: onRecordMealTap,
                    onMedicationTap: onMedicationTap,
                    onSourcesTap: onSourcesTap
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-screen")
    }
}

private struct TodayLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在加载今日证据…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

private struct TodayFailureView: View {
    let message: String
    let onRetryTap: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(CardTheme.activity.primary)
            Text("加载失败")
                .font(.title2.bold())
                .accessibilityIdentifier("today-load-error")
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: onRetryTap)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("today-retry")
        }
        .padding(28)
    }
}

private struct TodayLoadedContent: View {
    let presentation: TodayEvidencePresentation
    let onQualityTap: () -> Void
    let onSummaryTap: () -> Void
    let onTimelineTap: (TodayEvidencePresentation.TimelineRow.Kind) -> Void
    let onRecordMealTap: () -> Void
    let onMedicationTap: () -> Void
    let onSourcesTap: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                TodayHeader(
                    presentation: presentation,
                    onQualityTap: onQualityTap
                )

                TodayEvidenceCard(
                    presentation: presentation,
                    onSummaryTap: onSummaryTap,
                    onTimelineTap: onTimelineTap,
                    onRecordMealTap: onRecordMealTap,
                    onMedicationTap: onMedicationTap,
                    onSourcesTap: onSourcesTap
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }
}

private struct TodayHeader: View {
    let presentation: TodayEvidencePresentation
    let onQualityTap: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                title
                Spacer(minLength: 8)
                qualityPill
            }

            VStack(alignment: .leading, spacing: 10) {
                title
                qualityPill
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.headerTitle)
                .font(.largeTitle.bold())
            Text(presentation.dateText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var qualityPill: some View {
        Button(action: onQualityTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(qualityColor)
                    .frame(width: 8, height: 8)
                Text(presentation.qualityText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(qualityColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.qualityText)，查看数据质量")
        .accessibilityIdentifier("today-quality-pill")
    }

    private var qualityColor: Color {
        switch presentation.qualityStyle {
        case .unreconciled:
            return .gray
        case .reconciledNoAlerts:
            return .green
        case .hasAlerts:
            return .orange
        }
    }
}

private struct TodayEvidenceCard: View {
    let presentation: TodayEvidencePresentation
    let onSummaryTap: () -> Void
    let onTimelineTap: (TodayEvidencePresentation.TimelineRow.Kind) -> Void
    let onRecordMealTap: () -> Void
    let onMedicationTap: () -> Void
    let onSourcesTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TodayDailySummarySection(
                presentation: presentation,
                onSummaryTap: onSummaryTap
            )
            cardDivider
            TodayTimelineSection(
                presentation: presentation,
                onTimelineTap: onTimelineTap,
                onRecordMealTap: onRecordMealTap,
                onMedicationTap: onMedicationTap
            )
            cardDivider
            TodaySourceCoverageFooter(
                presentation: presentation,
                onSourcesTap: onSourcesTap
            )
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(CardTheme.sleep.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var cardDivider: some View {
        Divider()
            .padding(.horizontal, 18)
    }
}

private struct TodayDailySummarySection: View {
    let presentation: TodayEvidencePresentation
    let onSummaryTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeading(
                title: "当日汇总",
                subtitle: "日级证据，不代表具体发生时刻"
            )

            TodaySummaryRow(
                icon: "bed.double.fill",
                title: "当天睡眠汇总",
                summary: presentation.sleepSummary,
                theme: .sleep,
                identifier: "today-summary-sleep",
                action: onSummaryTap
            )
            TodaySummaryRow(
                icon: "figure.walk",
                title: "当天活动汇总",
                summary: presentation.activitySummary,
                theme: .activity,
                identifier: "today-summary-activity",
                action: onSummaryTap
            )
            TodaySummaryRow(
                icon: "flame.fill",
                title: "当日能量证据",
                summary: presentation.energySummary,
                theme: .deficit,
                identifier: "today-summary-energy",
                action: onSummaryTap
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private func sectionHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 5)
    }
}

private struct TodaySummaryRow: View {
    let icon: String
    let title: String
    let summary: TodayEvidencePresentation.SummaryText
    let theme: CardTheme
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .frame(width: 34, height: 34)
                    .background(theme.primary.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.valueText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    if let detail = summary.detailText {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("打开趋势")
    }
}

private struct TodayTimelineSection: View {
    let presentation: TodayEvidencePresentation
    let onTimelineTap: (TodayEvidencePresentation.TimelineRow.Kind) -> Void
    let onRecordMealTap: () -> Void
    let onMedicationTap: () -> Void

    var body: some View {
        let rows = presentation.timelineRows

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("记录时间线")
                    .font(.headline)
                Text("只显示已保存的餐食与用药事实")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        TodayTimelineRow(
                            row: row,
                            identifier: "today-timeline-\(row.id)"
                        ) {
                            onTimelineTap(row.kind)
                        }

                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-timeline")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.timelineEmptyText)
                .font(.callout)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    emptyButton(
                        title: "记录餐食",
                        icon: "fork.knife",
                        action: onRecordMealTap
                    )
                    emptyButton(
                        title: "查看用药",
                        icon: "pills",
                        action: onMedicationTap
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    emptyButton(
                        title: "记录餐食",
                        icon: "fork.knife",
                        action: onRecordMealTap
                    )
                    emptyButton(
                        title: "查看用药",
                        icon: "pills",
                        action: onMedicationTap
                    )
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func emptyButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
    }
}

private struct TodayTimelineRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: TodayEvidencePresentation.TimelineRow
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        timeAndIcon
                        rowCopy
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        timeAndIcon
                            .frame(minWidth: 70, alignment: .leading)
                        rowCopy
                        Spacer(minLength: 0)
                        chevron
                    }
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.kind == .meal ? "打开饮食" : "打开用药")
    }

    private var timeAndIcon: some View {
        HStack(spacing: 8) {
            Image(systemName: row.kind == .meal ? "fork.knife" : "pills.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.kind == .meal ? CardTheme.diet.primary : CardTheme.body.primary)
                .frame(width: 28, height: 28)
                .background(
                    (row.kind == .meal ? CardTheme.diet.primary : CardTheme.body.primary)
                        .opacity(0.11),
                    in: Circle()
                )
            Text(row.timeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var rowCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Text(row.primaryText)
                .font(.callout)
                .foregroundStyle(.primary)
                .monospacedDigit()
            if let detail = row.detailText {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let metadata = row.metadataText {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                chevron
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.bold())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct TodaySourceCoverageFooter: View {
    let presentation: TodayEvidencePresentation
    let onSourcesTap: () -> Void

    var body: some View {
        Button(action: onSourcesTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(CardTheme.body.primary)
                    Text("当日原始样本覆盖")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                if presentation.sourceCoverageRows.isEmpty {
                    Text(presentation.sourceCoverageEmptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presentation.sourceCoverageRows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(row.detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看数据来源")
        .accessibilityIdentifier("today-source-coverage")
    }
}

private enum TodayPreviewFixtures {
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "zh_CN")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()

    static let dayStart = DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 14
    ).date!

    static var loaded: TodayScreenState {
        let actionAt = dayStart.addingTimeInterval(8 * 3_600 + 12 * 60)
        let mealAt = dayStart.addingTimeInterval(11 * 3_600 + 28 * 60)
        let scheduledAt = dayStart.addingTimeInterval(20 * 3_600)
        let totals = MealNutritionTotals(
            caloriesKcal: 412,
            proteinG: 23,
            fatG: 14,
            carbsG: 46
        )
        let alerts = [
            TodayDataAlertEvidence(
                id: 1,
                metric: "sleep",
                severity: .warning,
                message: nil,
                createdAt: dayStart
            ),
            TodayDataAlertEvidence(
                id: 2,
                metric: "steps",
                severity: .info,
                message: nil,
                createdAt: dayStart.addingTimeInterval(1)
            )
        ]
        let snapshot = TodayEvidenceSnapshot(
            dayStart: dayStart,
            dayEndExclusive: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            dayKey: "2026-07-14",
            dailyAggregate: TodayDailyAggregateEvidence(
                wasComputed: true,
                computedAt: dayStart.addingTimeInterval(8 * 3_600),
                asleepSeconds: 7 * 3_600 + 24 * 60,
                steps: 2_340,
                activeEnergyKcal: 98,
                basalEnergyKcal: 1_500,
                distanceM: 1_600,
                exerciseMinutes: 20
            ),
            timelineEntries: [
                .medication(TodayMedicationEvidence(
                    id: 10,
                    planID: 1,
                    planName: "奥美拉唑",
                    scheduledAt: actionAt.addingTimeInterval(180),
                    actionAt: actionAt,
                    timelineAt: actionAt,
                    timeBasis: .actionTime,
                    action: .taken,
                    dosageMg: 20
                )),
                .meal(TodayMealEvidence(
                    id: 20,
                    mealType: .breakfast,
                    eatenAt: mealAt,
                    timelineAt: mealAt,
                    timeBasis: .eatenTime,
                    totals: totals,
                    itemCount: 1,
                    provenanceKinds: [.manual],
                    hasUserEditedItem: false
                )),
                .medication(TodayMedicationEvidence(
                    id: 11,
                    planID: 1,
                    planName: "奥美拉唑",
                    scheduledAt: scheduledAt,
                    actionAt: nil,
                    timelineAt: scheduledAt,
                    timeBasis: .scheduledFallback,
                    action: .deferred,
                    dosageMg: nil
                ))
            ],
            nutrition: MealNutritionEvidenceWindow(
                mealCount: 1,
                totals: totals,
                calories: .complete(412),
                days: [
                    MealNutritionDayEvidence(
                        date: dayStart,
                        mealCount: 1,
                        totals: totals,
                        calories: .complete(412)
                    )
                ]
            ),
            energyBalance: EnergyBalanceEvidence(
                activeKcal: 98,
                basalKcal: 1_500,
                intake: .complete(412)
            ),
            dataQuality: TodayDataQualityEvidence(
                wasReconciled: true,
                computedAt: dayStart.addingTimeInterval(8 * 3_600),
                completenessScore: 0.8,
                freshnessScore: 0.9,
                conflictScore: 0,
                missingMetricKeys: [],
                alerts: alerts
            ),
            sourceCoverage: [
                TodaySourceCoverageEvidence(
                    origin: .apple,
                    sourceName: "Apple Watch",
                    sampleCount: 24,
                    lastIngestedAt: dayStart.addingTimeInterval(8 * 3_600)
                )
            ]
        )
        return .loaded(
            TodayEvidencePresentation(
                calendar: calendar,
                locale: Locale(identifier: "zh_CN"),
                snapshot: snapshot
            )
        )
    }

    static var empty: TodayScreenState {
        let snapshot = TodayEvidenceSnapshot(
            dayStart: dayStart,
            dayEndExclusive: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            dayKey: "2026-07-14",
            dailyAggregate: .unavailable,
            timelineEntries: [],
            nutrition: .empty,
            energyBalance: EnergyBalanceEvidence(
                activeKcal: nil,
                basalKcal: nil,
                intake: .noMeals
            ),
            dataQuality: TodayDataQualityEvidence(
                wasReconciled: false,
                computedAt: nil,
                completenessScore: nil,
                freshnessScore: nil,
                conflictScore: nil,
                missingMetricKeys: nil,
                alerts: []
            ),
            sourceCoverage: []
        )
        return .loaded(
            TodayEvidencePresentation(
                calendar: calendar,
                locale: Locale(identifier: "zh_CN"),
                snapshot: snapshot
            )
        )
    }
}

#Preview("Loaded") {
    NavigationStack {
        TodayScreenContent(state: TodayPreviewFixtures.loaded)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Empty") {
    NavigationStack {
        TodayScreenContent(state: TodayPreviewFixtures.empty)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Loading") {
    NavigationStack {
        TodayScreenContent(state: .loading)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Failed") {
    NavigationStack {
        TodayScreenContent(state: .failed("今日数据暂时无法读取，请重试。"))
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Accessibility Large") {
    NavigationStack {
        TodayScreenContent(state: TodayPreviewFixtures.loaded)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}
