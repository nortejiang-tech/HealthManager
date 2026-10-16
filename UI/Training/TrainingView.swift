import SwiftUI
import GRDB

struct TrainingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var snapshot: TrainingSnapshot?
    @State private var loadError: String?
    @State private var observationError: String?
    @State private var isLoading = false
    @State private var revision = 0
    @State private var generation = 0
    @State private var window = 28
    @State private var showingMethod = false
    @State private var observation: AnyDatabaseCancellable?

    private var refreshKey: String { "\(revision)-\(sync.aggregationTick)-\(environment.localDataTick)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = loadError ?? observationError {
                        HMInlineRecovery(title: "锻炼数据暂未更新", message: "保留上次计算；恢复后重新读取。",
                            technicalDetails: error, actionTitle: "重新读取") {
                            Task { await refresh() }
                        }
                    }
                    if let snapshot {
                        TrainingReadinessCard(readiness: snapshot.readiness, isStale: loadError != nil) { showingMethod = true }
                        Picker("趋势窗口", selection: $window) {
                            Text("近7天").tag(7)
                            Text("近4周").tag(28)
                            Text("近8周").tag(56)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("training-window")
                        TrainingPerformancePanel(snapshot: snapshot, window: window)
                        TrainingLoadPanel(snapshot: snapshot, window: window)
                        TrainingRecoveryPanel(snapshot: snapshot, window: window)
                        TrainingHealthPanel(metrics: snapshot.health)
                        records(snapshot)
                        freshness(snapshot)
                    } else if isLoading {
                        ProgressView("正在计算锻炼与恢复趋势…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        HMEmptyState(title: "尚未读取锻炼数据", message: "同步Apple健康后，会根据已有记录计算表现、负荷与恢复趋势。",
                                     icon: "figure.run", tone: .neutral)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(HMColors.background.ignoresSafeArea())
            .navigationTitle("锻炼")
            .accessibilityIdentifier("training-screen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingMethod = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("计算依据与可信度")
                        .accessibilityIdentifier("training-method")
                }
            }
            .sheet(isPresented: $showingMethod) { TrainingMethodView(readiness: snapshot?.readiness) }
            .refreshable { await refresh() }
            .onAppear { startObservation() }
            .onDisappear { observation?.cancel(); observation = nil; generation &+= 1 }
            .task(id: refreshKey) {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                await refresh()
            }
            .task {
                // Visible-screen aging only. This does not claim new measurements were received.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(900)) } catch { return }
                    revision &+= 1
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { revision &+= 1 }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HMDateText.fullWeekday())
                .font(dynamicTypeSize.isAccessibilitySize ? .caption2 : .subheadline)
                .foregroundStyle(.secondary)
            if !dynamicTypeSize.isAccessibilitySize {
                Text("看见每次训练，也看见恢复")
                    .font(.title2.weight(.bold))
                Text("以基础心率、运动和睡眠记录计算；新记录进入后自动更新。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func records(_ snapshot: TrainingSnapshot) -> some View {
        TrainingPanel(title: "最近训练", icon: "figure.run") {
            if snapshot.sessions.isEmpty {
                Text("近8周没有已同步训练记录。可在同步中心回补，或补录活动。")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.sessions.prefix(5)) { session in
                NavigationLink { TrainingSessionDetail(session: session) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(WorkoutsView.label(for: session.activityType)).font(.headline)
                            Spacer()
                            Text(session.start, format: .dateTime.month().day()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        Text("\(TrainingText.number(session.distanceKm, unit: "km")) · \(Int(session.minutes.rounded())) 分钟 · \(TrainingText.pace(session.paceSecondsPerKm))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("training-session-\(session.id)")
            }
            NavigationLink("查看全部运动与补录", destination: WorkoutsView())
                .font(.subheadline.weight(.semibold))
        }
    }

    private func freshness(_ snapshot: TrainingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("数据时间", systemImage: "clock").font(.caption.weight(.semibold))
            Text("最近测量：\(TrainingText.time(snapshot.latestMeasurementAt))")
            Text("最近入库：\(TrainingText.time(snapshot.latestIngestionAt))")
            Text("本次计算：\(TrainingText.time(snapshot.calculatedAt))")
            Text("测量时间与计算时间分别展示。数据覆盖不代表医学准确度；准备度不用于诊断或判定伤病恢复。")
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink("查看同步状态", destination: SyncCenterView())
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("training-freshness")
    }

    private func startObservation() {
        guard observation == nil else { return }
        observationError = nil
        observation = DatabaseRegionObservation(tracking: Table("health_samples_raw"),
            Table("activity_metrics_daily"), Table("body_metrics_daily"))
            .start(in: environment.database.pool, onError: { error in
                Task { @MainActor in observationError = "数据变化监听失败：\(error.localizedDescription)" }
            }, onChange: { _ in
                Task { @MainActor in revision &+= 1 }
            })
    }

    @MainActor
    private func refresh() async {
        if observationError != nil { observation?.cancel(); observation = nil; startObservation() }
        generation &+= 1
        let request = generation
        isLoading = snapshot == nil
        defer { if request == generation { isLoading = false } }
        do {
            let loaded = try await TrainingSnapshotLoader.load(database: environment.database)
            guard !Task.isCancelled, request == generation else { return }
            snapshot = loaded
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            loadError = error.localizedDescription
        }
    }
}

struct TrainingPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(HMColors.confirmed)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .hmSurface()
    }
}

enum TrainingText {
    static func number(_ value: Double?, unit: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value) + (unit.isEmpty ? "" : " \(unit)")
    }
    static func pace(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "配速未知" }
        let total = Int(seconds.rounded())
        return String(format: "%d′%02d″/km", total / 60, total % 60)
    }
    static func time(_ date: Date?) -> String {
        date?.formatted(.dateTime.month().day().hour().minute()) ?? "暂无记录"
    }
}
