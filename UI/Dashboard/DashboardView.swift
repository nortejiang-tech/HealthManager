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
    @State private var showAlerts: Bool = false
    @State private var showQuality: Bool = false
    @State private var showingEditor: Bool = false
    @State private var metricPath: [MetricRoute] = []

    private let cardGrid: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack(path: $metricPath) {
            ScrollView {
                VStack(spacing: 14) {
                    HeroHeader(
                        snapshot: snapshot,
                        onAlertsTap: { showAlerts = true },
                        onQualityTap: { showQuality = true },
                        onMetricTap: { metricPath.append($0) }
                    )

                    LazyVGrid(columns: cardGrid, spacing: 12) {
                        ForEach(layout.visibleCards) { kind in
                            NavigationLink(value: kind.route) {
                                cardView(for: kind)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .animation(.snappy, value: layout.visibleCards)

                    if let err = loadError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }

                    if !layout.hiddenCards.isEmpty {
                        moreMetricsSection
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }

                    VStack(spacing: 0) {
                        NavigationLink {
                            DataQualityDetailView()
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet.rectangle")
                                Text("数据质量 / 同步明细 / 报告")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 14)
                        NavigationLink {
                            WorkoutsView()
                        } label: {
                            HStack {
                                Image(systemName: "figure.run")
                                Text("运动记录")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                    Spacer(minLength: 24)
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("摘要")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("编辑卡片")
                }
            }
            .sheet(isPresented: $showingEditor) {
                DashboardCardEditor(store: layout)
            }
            .navigationDestination(for: MetricRoute.self) { route in
                MetricDetailView(config: route.config)
            }
            .navigationDestination(isPresented: $showAlerts) { AlertsView() }
            .navigationDestination(isPresented: $showQuality) { DataQualityDetailView() }
            .refreshable { await refresh() }
            .task { await refresh() }
            .onChange(of: sync.aggregationTick) { _, _ in
                Task { await refresh() }
            }
            .onChange(of: sync.lastResult) { _, _ in
                Task { await refresh() }
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
        case .exercise:
            SlimMetricCard(
                kind: kind,
                value: snapshot.activity.todayExerciseMin,
                unit: "min",
                format: { String(format: "%.0f", $0) }
            )
        case .hrv:
            SlimMetricCard(
                kind: kind,
                value: snapshot.heart.todayHRV,
                unit: "ms",
                format: { String(format: "%.0f", $0) }
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

    @ViewBuilder
    private var moreMetricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("更多指标")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(layout.hiddenCards.enumerated()), id: \.element) { idx, kind in
                    moreMetricRow(kind: kind)
                    if idx < layout.hiddenCards.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func moreMetricRow(kind: DashboardCardKind) -> some View {
        NavigationLink(value: kind.route) {
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
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loader = DashboardLoader(database: environment.database)
            let snap = try await loader.loadSnapshot()
            await MainActor.run {
                self.snapshot = snap
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = "加载失败：\(error.localizedDescription)"
            }
            AppLogger.shared.error("Dashboard refresh failed: \(error.localizedDescription)")
        }
    }
}

/// Routes for each card → detail screen.
enum MetricRoute: Hashable {
    case steps, activeKcal, restingHR, hrv, sleep, weight, bodyFat, bmi, diet, deficit, exercise, distance

    var config: MetricDetailConfig {
        switch self {
        case .steps: return .steps
        case .activeKcal: return .activeKcal
        case .restingHR: return .restingHR
        case .hrv: return .hrv
        case .sleep: return .sleep
        case .weight: return .weight
        case .bodyFat: return .bodyFat
        case .bmi: return .bmi
        case .exercise: return .exercise
        case .distance: return .distance
        case .diet: return .diet
        case .deficit: return .deficit
        }
    }
}
