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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TodayStateHeader(
                    tone: .neutral,
                    status: "正在读取本机证据",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                Text("正在整理\n今天的数据")
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                TodayBaselineSkeleton()

                TodayLoadingLens()

                TodayLoadingSummary()

                VStack(spacing: 0) {
                    TodayLoadingRow()
                    Divider().overlay(HMColors.separator)
                    TodayLoadingRow()
                }

                Label(
                    "只读取本机数据库；完成后会显示来源、缺失与估算状态。",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .background(HMColors.background.ignoresSafeArea())
        .accessibilityIdentifier("today-loading")
    }
}

private struct TodayStateHeader: View {
    let tone: HMSemanticTone
    let status: String
    let systemImage: String

    @Environment(\.locale) private var locale

    private var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = TodayEvidencePresentation.resolvedInterfaceLocale(
            environmentLocale: locale
        )
        formatter.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return formatter.string(from: Date())
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                HMEditorialHeader(title: "今日", subtitle: dateLabel)
                HMEvidenceTag(
                    tone: tone,
                    text: status,
                    systemImage: systemImage
                )
            }
            VStack(alignment: .leading, spacing: 14) {
                HMEditorialHeader(title: "今日", subtitle: dateLabel)
                HMEvidenceTag(
                    tone: tone,
                    text: status,
                    systemImage: systemImage
                )
            }
        }
    }
}

private struct TodayBaselineSkeleton: View {
    private let nodePositions: [(CGFloat, CGFloat)] = [
        (0.07, 0.72),
        (0.43, 0.45),
        (0.82, 0.28)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    path.move(to: CGPoint(x: 0, y: height * 0.66))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.32),
                        control1: CGPoint(x: width * 0.24, y: height * 0.95),
                        control2: CGPoint(x: width * 0.63, y: height * 0.12)
                    )
                }
                .stroke(HMColors.skeleton, style: StrokeStyle(lineWidth: 4, lineCap: .round))

                ForEach(nodePositions.indices, id: \.self) { index in
                    let position = nodePositions[index]
                    Circle()
                        .fill(HMColors.background)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle()
                                .stroke(HMColors.skeleton, lineWidth: 5)
                        }
                        .position(
                            x: proxy.size.width * position.0,
                            y: proxy.size.height * position.1
                        )
                }

                VStack(alignment: .leading, spacing: 10) {
                    HMLoadingSkeleton(width: proxy.size.width * 0.34, height: 16)
                    HMLoadingSkeleton(width: proxy.size.width * 0.23, height: 12)
                }
                .offset(x: proxy.size.width * 0.07, y: 8)

                VStack(alignment: .leading, spacing: 10) {
                    HMLoadingSkeleton(width: proxy.size.width * 0.26, height: 16)
                    HMLoadingSkeleton(width: proxy.size.width * 0.17, height: 12)
                }
                .offset(x: proxy.size.width * 0.55, y: 22)
            }
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }
}

private struct TodayLoadingLens: View {
    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(HMColors.skeleton)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 10) {
                HMLoadingSkeleton(height: 16)
                HMLoadingSkeleton(width: 170, height: 12)
            }
        }
        .padding(20)
        .hmSurface(cornerRadius: 22)
        .accessibilityHidden(true)
    }
}

private struct TodayLoadingSummary: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                summaryItem
                Divider().overlay(HMColors.separator)
                summaryItem
                Divider().overlay(HMColors.separator)
                summaryItem
            }
            Divider().overlay(HMColors.separator)
            HStack(spacing: 14) {
                loadingBlock
                loadingBlock
            }
            Divider().overlay(HMColors.separator)
            HMLoadingSkeleton(width: 190, height: 12)
        }
        .padding(20)
        .hmSurface(cornerRadius: 18)
        .accessibilityHidden(true)
    }

    private var summaryItem: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(HMColors.skeleton)
                .frame(width: 28, height: 28)
            HMLoadingSkeleton(height: 12)
        }
    }

    private var loadingBlock: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(HMColors.skeleton)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
    }
}

private struct TodayLoadingRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(HMColors.skeleton)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 9) {
                HMLoadingSkeleton(width: 130, height: 14)
                HMLoadingSkeleton(width: 190, height: 12)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 18)
        .accessibilityHidden(true)
    }
}

private struct TodayFailureView: View {
    let message: String
    let onRetryTap: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TodayStateHeader(
                    tone: .actionRequired,
                    status: "读取失败",
                    systemImage: "exclamationmark.circle.fill"
                )

                HMInlineRecovery(
                    title: "今天的数据暂时没有整理完成",
                    message: "这次读取没有删除本地记录。你可以重新读取今日页面。",
                    technicalDetails: message,
                    actionTitle: "重新读取",
                    onAction: onRetryTap,
                    titleAccessibilityIdentifier: "today-load-error",
                    actionAccessibilityIdentifier: "today-retry"
                )

                VStack(spacing: 0) {
                    HMInformationRow(
                        systemImage: "externaldrive.fill",
                        tone: .confirmed,
                        title: "本地记录",
                        detail: "本次失败不会清除已有数据",
                        trailingText: "保留",
                        trailingTone: .confirmed
                    )
                    Divider().overlay(HMColors.separator)
                    HMInformationRow(
                        systemImage: "arrow.clockwise",
                        tone: .comparison,
                        title: "重试范围",
                        detail: "只重新读取今日证据",
                        trailingText: "今日",
                        trailingTone: .comparison
                    )
                }
                .padding(.horizontal, 16)
                .hmSurface(cornerRadius: 18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .background(HMColors.background.ignoresSafeArea())
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

                TodayDecisionPanel(
                    presentation: presentation
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
        .background(HMColors.background.ignoresSafeArea())
    }
}

private struct TodayHeader: View {
    let presentation: TodayEvidencePresentation
    let onQualityTap: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                HMEditorialHeader(
                    title: presentation.headerTitle,
                    subtitle: presentation.dateText
                )
                qualityPill
            }

            VStack(alignment: .leading, spacing: 12) {
                HMEditorialHeader(
                    title: presentation.headerTitle,
                    subtitle: presentation.dateText
                )
                qualityPill
            }
        }
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
            .overlay(Capsule().stroke(qualityColor.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.qualityText)，查看数据质量")
        .accessibilityIdentifier("today-quality-pill")
    }

    private var qualityColor: Color {
        switch presentation.qualityStyle {
        case .unreconciled:
            return HMColors.neutral
        case .reconciledNoAlerts:
            return HMColors.confirmed
        case .hasAlerts:
            return HMColors.actionRequired
        }
    }
}

private struct TodayDecisionPanel: View {
    let presentation: TodayEvidencePresentation

    var body: some View {
        HMDecisionLens(
            title: lensTitle,
            text: lensNarrative,
            tone: lensTone,
            systemImage: lensIcon
        )
        .accessibilityIdentifier("today-decision-lens")
    }

    private var lensTone: HMSemanticTone {
        if presentation.qualityStyle == .hasAlerts { return .actionRequired }
        if !presentation.timelineRows.isEmpty { return .confirmed }
        return .neutral
    }

    private var lensIcon: String {
        presentation.qualityStyle == .hasAlerts ? "exclamationmark.circle.fill" : "scope"
    }

    private var lensTitle: String {
        if presentation.qualityStyle == .hasAlerts { return "先核对待处理项" }
        return presentation.timelineRows.isEmpty ? "今日记录基线" : "值得查看的事实"
    }

    private var lensNarrative: String {
        if presentation.qualityStyle == .hasAlerts {
            return "当前数据质量有待处理项。先核对来源，再据此查看当日记录。"
        }
        if presentation.timelineRows.isEmpty {
            return "今天还没有已保存的餐食或用药动作；当日汇总仍按现有样本展示。"
        }
        return "今天收录了 \(presentation.timelineRows.count) 条餐食或用药事实，并覆盖 \(presentation.sourceCoverageRows.count) 类原始样本。"
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
            Divider()
                .overlay(HMColors.separator)
                .padding(.leading, 18)
                .padding(.trailing, 18)

            TodayTimelineSection(
                presentation: presentation,
                onTimelineTap: onTimelineTap,
                onRecordMealTap: onRecordMealTap,
                onMedicationTap: onMedicationTap
            )

            Divider()
                .overlay(HMColors.separator)
                .padding(.leading, 18)
                .padding(.trailing, 18)

            TodaySourceCoverageFooter(
                presentation: presentation,
                onSourcesTap: onSourcesTap
            )
        }
        .hmSurface(cornerRadius: 22)
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
                .font(.title3.weight(.semibold))
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

#Preview("Loading (Dark)") {
    NavigationStack {
        TodayScreenContent(state: .loading)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .preferredColorScheme(.dark)
}

#Preview("Loading (Accessibility Large)") {
    NavigationStack {
        TodayScreenContent(state: .loading)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Failed") {
    NavigationStack {
        TodayScreenContent(state: .failed("今日数据暂时无法读取，请重试。"))
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Failed (Dark)") {
    NavigationStack {
        TodayScreenContent(state: .failed("今日数据暂时无法读取，请重试。"))
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .preferredColorScheme(.dark)
}

#Preview("Failed (Accessibility Large)") {
    NavigationStack {
        TodayScreenContent(state: .failed("今日数据暂时无法读取，请重试。"))
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Accessibility Large") {
    NavigationStack {
        TodayScreenContent(state: TodayPreviewFixtures.loaded)
    }
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}
