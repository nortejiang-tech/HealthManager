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

    private let cardGrid: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HeroHeader(
                        snapshot: snapshot,
                        onAlertsTap: { showAlerts = true },
                        onQualityTap: { showQuality = true }
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

                    NavigationLink {
                        DataQualityDetailView()
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                            Text("数据质量 / 同步明细 / 报告")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
        }
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
        case .diet:
            // Diet lives in meal_records, not the daily projection tables.
            // We still surface the calories series via the per-day activity table fallback;
            // until a meal_daily table is introduced, show the active kcal view as a proxy.
            return .activeKcal
        case .deficit:
            // Deficit is derived (active+basal − intake). For the detail page we surface the
            // active-kcal trend as the closest readily-available proxy.
            return .activeKcal
        }
    }
}
