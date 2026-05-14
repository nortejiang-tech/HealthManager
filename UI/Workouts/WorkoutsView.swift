import SwiftUI
import GRDB

/// Lists `HKWorkout` samples ingested into `health_samples_raw`.
///
/// Each row decodes `extra_json` to surface activityType / duration / energy / distance
/// — fields V1 stowed but never displayed. Tap to expand into details (raw JSON).
struct WorkoutsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var rows: [WorkoutRow] = []
    @State private var windowDays: Int = 30

    struct WorkoutRow: Identifiable, Hashable {
        let sampleUUID: String
        let startAt: Int64
        let endAt: Int64
        let durationSeconds: Double
        let activityType: Int
        let activityLabel: String
        let energyKcal: Double?
        let distanceMeters: Double?
        let sourceLabel: String

        var id: String { sampleUUID }
    }

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
                        WorkoutRowView(row: row)
                    }
                }
            }
        }
        .navigationTitle("运动")
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do {
            let cal = Calendar.current
            let earliest = cal.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
            let earliestEpoch = Int64(earliest.timeIntervalSince1970)
            let loaded = try await environment.database.asyncRead { db -> [WorkoutRow] in
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
                return dbRows.map { r in
                    let extra = (r["extra_json"] as String?).flatMap { Self.decode($0) } ?? [:]
                    let actType = (extra["activityType"] as? Int) ?? 0
                    let energy = extra["totalEnergyKcal"] as? Double
                    let distance = extra["totalDistanceMeters"] as? Double
                    let origin = SourceAttribution.Origin(rawValue: r["source_origin"] ?? "unknown")?.label ?? "未识别"
                    return WorkoutRow(
                        sampleUUID: r["sample_uuid"] ?? "",
                        startAt: r["start_at"] ?? 0,
                        endAt: r["end_at"] ?? 0,
                        durationSeconds: r["duration"] ?? 0,
                        activityType: actType,
                        activityLabel: Self.label(for: actType),
                        energyKcal: energy,
                        distanceMeters: distance,
                        sourceLabel: origin
                    )
                }
            }
            await MainActor.run { rows = loaded }
        } catch {
            AppLogger.shared.error("Workouts refresh failed: \(error.localizedDescription)")
        }
    }

    private static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Subset of `HKWorkoutActivityType` raw values → Chinese label.
    /// Unknown values fall back to "运动 (#raw)".
    static func label(for type: Int) -> String {
        switch type {
        case 13: return "骑行"
        case 16: return "椭圆机"
        case 24: return "徒步"
        case 35: return "划船"
        case 37: return "跑步"
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

private struct WorkoutRowView: View {
    let row: WorkoutsView.WorkoutRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.activityLabel).font(.body.bold())
                Spacer()
                Text(dateLabel).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(durationLabel)
                if let e = row.energyKcal {
                    Text(String(format: "%.0f kcal", e))
                }
                if let d = row.distanceMeters, d > 0 {
                    Text(String(format: "%.2f km", d / 1000))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(row.sourceLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(row.startAt)))
    }

    private var durationLabel: String {
        let mins = Int(row.durationSeconds / 60)
        if mins >= 60 {
            return "\(mins / 60)h\(mins % 60)m"
        }
        return "\(mins) 分钟"
    }
}
