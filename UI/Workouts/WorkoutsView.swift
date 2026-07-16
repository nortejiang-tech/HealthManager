import SwiftUI
import GRDB

/// Lists `HKWorkout` samples ingested into `health_samples_raw`.
///
/// Each row decodes `extra_json` to surface activityType / duration / energy / distance
/// — fields V1 stowed but never displayed. Tap to expand into details (raw JSON).
struct WorkoutsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var rows: [ActivityWorkoutRow] = []
    @State private var windowDays: Int = 30
    @State private var showingManualEntry: Bool = false
    @State private var loadError: String?

    var body: some View {
        List {
            Section("窗口") {
                Stepper("过去 \(windowDays) 天", value: $windowDays, in: 7...180, step: 7)
                    .onChange(of: windowDays) { Task { await refresh() } }
            }
            if let loadError {
                Section {
                    HMInlineRecovery(
                        title: "运动记录加载失败",
                        message: "现有记录没有被修改。可在当前页面重新读取。",
                        technicalDetails: loadError,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
            } else if rows.isEmpty {
                Section {
                    HMEmptyState(
                        title: "窗口内暂无运动样本",
                        message: "这不代表活动能量为 0。可先回补 Apple 健康数据，或补录一条估算活动。",
                        icon: "figure.run",
                        tone: .neutral,
                        primaryActionTitle: "补录活动",
                        primaryActionIcon: "plus",
                        primaryAction: { showingManualEntry = true }
                    )
                }
            } else {
                Section("记录边界") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            evidenceTags
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            evidenceTags
                        }
                    }
                }
                Section {
                    ForEach(rows) { row in
                        ActivityWorkoutRowView(row: row)
                    }
                } header: {
                    Text("最近运动（\(rows.count) 次）")
                } footer: {
                    Text("补录记录的消耗来自 MET × 体重 × 小时估算；同步记录按原始来源展示。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("运动")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingManualEntry = true } label: {
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
    }

    @ViewBuilder
    private var evidenceTags: some View {
                        HMEvidenceTag(
                            tone: .confirmed,
                            text: "同步 \(syncedCount)",
                            systemImage: "checkmark.shield"
                        )
                        HMEvidenceTag(
                            tone: .estimate,
                            text: "补录 \(manualCount)",
                            systemImage: "square.and.pencil"
                        )
    }

    private func refresh() async {
        do {
            let cal = Calendar.current
            let earliest = cal.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
            let earliestEpoch = Int64(earliest.timeIntervalSince1970)
            let loaded = try await environment.database.asyncRead { db -> [ActivityWorkoutRow] in
                let dbRows = try Row.fetchAll(db, sql: """
                    SELECT sample_uuid, start_at, end_at, value AS duration,
                           extra_json, source_name, source_origin
                    FROM health_samples_raw
                    WHERE is_deleted = 0
                      AND hk_type = ?
                      AND start_at >= ?
                    ORDER BY start_at DESC
                    LIMIT 200
                    """, arguments: ["HKWorkoutTypeIdentifier", earliestEpoch])
                return dbRows.map(ActivityWorkoutRow.make(from:))
            }
            await MainActor.run {
                rows = loaded
                loadError = nil
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Workouts refresh failed: \(error.localizedDescription)")
        }
    }

    private var manualCount: Int {
        rows.filter(\.isManualEstimate).count
    }

    private var syncedCount: Int { rows.count - manualCount }

    /// Subset of `HKWorkoutActivityType` raw values → Chinese label.
    /// Unknown values fall back to "运动 (#raw)".
    static func label(for type: Int) -> String {
        switch type {
        case 5: return "棒球"
        case 6: return "篮球"
        case 13: return "骑行"
        case 16: return "椭圆机"
        case 24: return "徒步"
        case 35: return "划船"
        case 37: return "跑步"
        case 41: return "足球"
        case 46: return "游泳"
        case 52: return "步行"
        case 63: return "瑜伽"
        case 70: return "登山"
        case 74: return "力量训练"
        case 79: return "HIIT"
        case 83: return "跳绳"
        case 3000: return "其他"
        default: return "运动 #\(type)"
        }
    }
}
