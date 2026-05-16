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

    var body: some View {
        List {
            Section("窗口") {
                Stepper("过去 \(windowDays) 天", value: $windowDays, in: 7...180, step: 7)
                    .onChange(of: windowDays) { Task { await refresh() } }
            }
            if rows.isEmpty {
                Section {
                    Text("窗口内没有运动样本。先回补一次，或检查 Apple 健康是否有运动数据。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("最近运动（\(rows.count) 次）") {
                    ForEach(rows) { row in
                        ActivityWorkoutRowView(row: row)
                    }
                }
            }
        }
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
            await MainActor.run { rows = loaded }
        } catch {
            AppLogger.shared.error("Workouts refresh failed: \(error.localizedDescription)")
        }
    }

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
