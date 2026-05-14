import SwiftUI

/// Apple Health 风格摘要页：hero header + 2 列 6 卡片 + 详情页（周/月/年）。
/// 所有 DB 查询通过 `DatabaseManager.asyncRead` 走后台执行器，不阻塞主线程。
struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var snapshot: DashboardSnapshot = DashboardSnapshot()
    @State private var loadError: String?
    @State private var isLoading: Bool = true
    @State private var showAlerts: Bool = false
    @State private var showQuality: Bool = false
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
                        NavigationLink(value: MetricRoute.steps) {
                            ActivityCard(data: snapshot.activity)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: MetricRoute.restingHR) {
                            HeartCard(data: snapshot.heart)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: MetricRoute.sleep) {
                            SleepCard(data: snapshot.sleep)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: MetricRoute.weight) {
                            BodyCard(data: snapshot.body_)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: MetricRoute.diet) {
                            DietCard(data: snapshot.diet)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(value: MetricRoute.deficit) {
                            DeficitCard(data: snapshot.deficit)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)

                    if let err = loadError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }

                    moreMetricsSection
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

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

    @ViewBuilder
    private var moreMetricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("更多指标")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                moreMetricRow(route: .activeKcal, icon: "flame.fill", tint: CardTheme.activity.primary, title: "活动能量")
                Divider().padding(.leading, 44)
                moreMetricRow(route: .exercise, icon: "stopwatch.fill", tint: CardTheme.activity.primary, title: "锻炼时长")
                Divider().padding(.leading, 44)
                moreMetricRow(route: .distance, icon: "figure.walk.motion", tint: CardTheme.activity.primary, title: "距离")
                Divider().padding(.leading, 44)
                moreMetricRow(route: .hrv, icon: "waveform.path.ecg", tint: CardTheme.heart.primary, title: "心率变异性")
                Divider().padding(.leading, 44)
                moreMetricRow(route: .bodyFat, icon: "figure", tint: CardTheme.body.primary, title: "体脂率")
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func moreMetricRow(route: MetricRoute, icon: String, tint: Color, title: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
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
    case steps, activeKcal, restingHR, hrv, sleep, weight, bodyFat, diet, deficit, exercise, distance

    var config: MetricDetailConfig {
        switch self {
        case .steps: return .steps
        case .activeKcal: return .activeKcal
        case .restingHR: return .restingHR
        case .hrv: return .hrv
        case .sleep: return .sleep
        case .weight: return .weight
        case .bodyFat: return .bodyFat
        case .exercise: return .exercise
        case .distance: return .distance
        case .diet: return .diet
        case .deficit: return .deficit
        }
    }
}
