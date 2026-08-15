import SwiftUI

/// Apple Health 风格摘要页：hero header + 用户自定义的卡片网格 + 详情页（周/月/年）。
/// 所有 DB 查询通过 `DatabaseManager.asyncRead` 走后台执行器，不阻塞主线程。
struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @StateObject private var layout = DashboardLayoutStore()

    @State private var snapshot: DashboardSnapshot = DashboardSnapshot()
    @State private var loadError: String?
    @State private var isLoading: Bool = true
    @State private var hasLoadedSnapshot: Bool = false
    @State private var refreshGeneration: Int = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var showAlerts: Bool = false
    @State private var showQuality: Bool = false
    @State private var showingEditor: Bool = false
    @State private var metricPath: [MetricRoute] = []

    var body: some View {
        NavigationStack(path: $metricPath) {
            DashboardScreenContent(
                snapshot: snapshot,
                isLoading: isLoading,
                hasLoadedSnapshot: hasLoadedSnapshot,
                loadError: loadError,
                visibleCards: layout.visibleCards,
                hiddenCards: layout.hiddenCards,
                onAlertsTap: { showAlerts = true },
                onQualityTap: { showQuality = true },
                onMetricTap: { metricPath.append($0) },
                onRetry: {
                    await refresh()
                },
                cardView: { kind in
                    AnyView(cardView(for: kind))
                }
            )
            .navigationTitle("趋势")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier("dashboard-edit-cards")
                    .accessibilityLabel("编辑卡片")
                }
            }
            .sheet(isPresented: $showingEditor) {
                DashboardCardEditor(store: layout)
            }
            .navigationDestination(for: MetricRoute.self) { route in
                if let config = route.config {
                    MetricDetailView(config: config)
                } else {
                    ActivityDetailView()
                }
            }
            .navigationDestination(isPresented: $showAlerts) { AlertsView() }
            .navigationDestination(isPresented: $showQuality) { DataQualityDetailView() }
            .refreshable { await refresh() }
            .task { await refresh() }
            .onChange(of: sync.aggregationTick) { _, _ in
                scheduleCoalescedRefresh()
            }
            .onChange(of: sync.lastResult) { _, _ in
                scheduleCoalescedRefresh()
            }
            .onChange(of: environment.localDataTick) { _, _ in
                scheduleCoalescedRefresh()
            }
        }
    }

    /// Render whichever card belongs in this slot. Rich kinds reuse their bespoke
    /// views; slim kinds funnel through `SlimMetricCard`.
    @ViewBuilder
    private func cardView(for kind: DashboardCardKind) -> some View {
        switch kind {
        case .activity:
            ActivityCard(data: snapshot.activity)
        case .heart:
            HeartCard(data: snapshot.heart)
        case .sleep:
            SleepCard(data: snapshot.sleep)
        case .body:
            BodyCard(data: snapshot.body_)
        case .diet:
            DietCard(data: snapshot.diet)
        case .deficit:
            DeficitCard(data: snapshot.deficit)
        case .activeKcal:
            SlimMetricCard(
                kind: kind,
                value: snapshot.activity.todayActiveKcal,
                unit: "kcal",
                format: { String(format: "%.0f", $0) }
            )
        case .distance:
            SlimMetricCard(
                kind: kind,
                value: snapshot.activity.todayDistanceM,
                unit: "km",
                format: { String(format: "%.2f", $0 / 1000) }
            )
        case .bodyFat:
            SlimMetricCard(
                kind: kind,
                value: snapshot.body_.latestBodyFatPct,
                unit: "%",
                format: { String(format: "%.1f", $0 * 100) }
            )
        case .bmi:
            SlimMetricCard(
                kind: kind,
                value: snapshot.body_.latestBmi,
                unit: nil,
                format: { String(format: "%.1f", $0) },
                caption: bmiCaption(snapshot.body_.latestBmi)
            )
        }
    }

    private func bmiCaption(_ bmi: Double?) -> String? {
        guard let bmi else { return nil }
        let zone: String
        switch bmi {
        case ..<18.5: zone = "偏瘦"
        case 18.5..<24.0: zone = "正常"
        case 24.0..<28.0: zone = "超重"
        default: zone = "肥胖"
        }
        return zone
    }

    /// 合并短时间内连续到达的刷新信号（一次同步会同时触发 aggregationTick /
    /// lastResult / localDataTick 三个 onChange）：只保留最后一次，350ms 后执行。
    private func scheduleCoalescedRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let shouldShowInitialLoading = !hasLoadedSnapshot
        if shouldShowInitialLoading {
            isLoading = true
        }
        loadError = nil
        do {
            let loader = DashboardLoader(database: environment.database)
            let snap = try await loader.loadSnapshot()
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.snapshot = snap
                self.loadError = nil
                self.hasLoadedSnapshot = true
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.loadError = "加载失败：\(error.localizedDescription)"
                self.isLoading = false
            }
            AppLogger.shared.error("Dashboard refresh failed: \(error.localizedDescription)")
        }
    }
}

private struct DashboardScreenContent: View {
    let snapshot: DashboardSnapshot
    let isLoading: Bool
    let hasLoadedSnapshot: Bool
    let loadError: String?
    let visibleCards: [DashboardCardKind]
    let hiddenCards: [DashboardCardKind]
    let onAlertsTap: () -> Void
    let onQualityTap: () -> Void
    let onMetricTap: (MetricRoute) -> Void
    let onRetry: () async -> Void
    let cardView: (DashboardCardKind) -> AnyView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(HMDateText.fullWeekday())
                    .font(.body)
                    .foregroundStyle(.secondary)

                if isLoading {
                    DashboardLoadingHero()
                } else if hasLoadedSnapshot {
                    HeroHeader(
                        snapshot: snapshot,
                        onAlertsTap: onAlertsTap,
                        onQualityTap: onQualityTap,
                        onMetricTap: onMetricTap
                    )
                }

                if let loadError {
                    HMInlineRecovery(
                        title: "趋势摘要读取失败",
                        message: "本地指标暂时无法更新；可以重试本次读取。",
                        technicalDetails: loadError,
                        actionTitle: "重试",
                        onAction: {
                            Task { await onRetry() }
                        },
                        titleAccessibilityIdentifier: "dashboard-load-error-title",
                        actionAccessibilityIdentifier: "dashboard-retry"
                    )
                }

                if isLoading || hasLoadedSnapshot {
                    DashboardCardGrid(
                        isLoading: isLoading,
                        visibleCards: visibleCards,
                        onMetricTap: onMetricTap,
                        cardView: cardView
                    )
                }

                if hasLoadedSnapshot, !hiddenCards.isEmpty {
                    DashboardHiddenMetricsSection(
                        kinds: hiddenCards,
                        isLoading: isLoading,
                        onMetricTap: onMetricTap
                    )
                }

                DashboardQuickLinksSection(onQualityTap: onQualityTap)

                if hasLoadedSnapshot {
                    HMProvenanceRail(
                        title: "指标从哪里来",
                        steps: provenanceSteps
                    )
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
        .accessibilityIdentifier("dashboard-screen")
    }

    private var provenanceSteps: [HMProvenanceRail.Step] {
        [
            .init(
                title: "来源",
                detail: "Apple 健康与手工记录",
                tone: .confirmed,
                systemImage: "dot.radiowaves.left.and.right",
                accessibilityIdentifier: "dashboard-provenance-steps-healthkit"
            ),
            .init(
                title: "整理",
                detail: "在本机按日汇总",
                tone: .comparison,
                systemImage: "square.stack.3d.down.right",
                accessibilityIdentifier: "dashboard-provenance-steps-aggregation"
            ),
            .init(
                title: "展示",
                detail: "进入趋势与明细",
                tone: .comparison,
                systemImage: "scope",
                accessibilityIdentifier: "dashboard-provenance-steps-presentation"
            )
        ]
    }
}

private struct DashboardLoadingHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HMEvidenceTag(
                    tone: .neutral,
                    text: "趋势加载中",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                Spacer()
                HMLoadingSkeleton(width: 56, height: 28, cornerRadius: 14)
            }

            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        HMLoadingSkeleton(width: 28, height: 28, cornerRadius: 14)
                        HMLoadingSkeleton(height: 26)
                        HMLoadingSkeleton(width: 52, height: 14)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .hmSurface(cornerRadius: 16)
        .accessibilityLabel("趋势主摘要加载中")
    }
}

private struct DashboardCardGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isLoading: Bool
    let visibleCards: [DashboardCardKind]
    let onMetricTap: (MetricRoute) -> Void
    let cardView: (DashboardCardKind) -> AnyView

    private let cardGrid: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("指标")
                .font(.title3.weight(.semibold))

            if isLoading {
                VStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        HMLoadingSkeleton(height: 120, cornerRadius: 16)
                    }
                }
            } else {
                LazyVGrid(columns: cardGrid, spacing: 12) {
                    ForEach(visibleCards) { kind in
                        Button {
                            onMetricTap(kind.route)
                        } label: {
                            cardView(kind)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: visibleCards)
    }
}

private struct DashboardHiddenMetricsSection: View {
    let kinds: [DashboardCardKind]
    let isLoading: Bool
    let onMetricTap: (MetricRoute) -> Void

    var body: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: 10) {
                Text("更多指标")
                    .font(.title3.weight(.semibold))
                HMLoadingSkeleton(height: 120, cornerRadius: 16)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("更多指标")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { idx, kind in
                        moreMetricRow(kind: kind)
                        if idx < kinds.count - 1 {
                            Divider().overlay(HMColors.separator).padding(.leading, 44)
                        }
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(HMColors.separator, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func moreMetricRow(kind: DashboardCardKind) -> some View {
        Button {
            onMetricTap(kind.route)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind.theme.primary)
                    .frame(width: 24, height: 24)
                    .background(kind.theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(kind.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardQuickLinksSection: View {
    let onQualityTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onQualityTap) {
                dashboardLinkLabel(
                    title: "数据质量 / 同步明细 / 报告",
                    systemImage: "list.bullet.rectangle"
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(HMColors.separator).padding(.leading, 14)

            NavigationLink {
                WorkoutsView()
            } label: {
                dashboardLinkLabel(
                    title: "运动记录",
                    systemImage: "figure.run"
                )
            }
            .buttonStyle(.plain)
        }
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HMColors.separator, lineWidth: 1)
        )
    }

    private func dashboardLinkLabel(title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
            Text(title)
                .font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Routes for each card -> detail screen.
enum MetricRoute: Hashable {
    case activity, steps, activeKcal, restingHR, sleep, weight, bodyFat, bmi, diet, deficit, distance

    var config: MetricDetailConfig? {
        switch self {
        case .activity: return nil
        case .steps: return .steps
        case .activeKcal: return .activeKcal
        case .restingHR: return .restingHR
        case .sleep: return .sleep
        case .weight: return .weight
        case .bodyFat: return .bodyFat
        case .bmi: return .bmi
        case .distance: return .distance
        case .diet: return .diet
        case .deficit: return .deficit
        }
    }
}

#Preview("Dashboard loaded") {
    DashboardView()
        .environmentObject(AppEnvironment.shared)
        .environmentObject(AppEnvironment.shared.syncEngine)
}

#Preview("Dashboard loaded (Dark)") {
    DashboardView()
        .environmentObject(AppEnvironment.shared)
        .environmentObject(AppEnvironment.shared.syncEngine)
        .preferredColorScheme(.dark)
}

#Preview("Dashboard loaded (Accessibility Large)") {
    DashboardView()
        .environmentObject(AppEnvironment.shared)
        .environmentObject(AppEnvironment.shared.syncEngine)
        .environment(\.dynamicTypeSize, .accessibility2)
}
