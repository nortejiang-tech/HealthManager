import SwiftUI
import GRDB

/// Shows where data comes from — attribution dashboard for PRD §4 / 来源归因.
///
/// V3: queries the `source_origin` column populated by `SampleMapper` /
/// `v2_add_source_origin` migration. The view supports two groupings:
/// - by attribution Origin (Garmin / 米家 / Apple …) — coarse, defensible
/// - by raw `source_bundle_id` — fine-grained, useful when you suspect a specific app
///
/// Aggregates over `health_samples_raw` directly so the freshness reflects today's
/// writes, not just the last source_coverage_daily rollup.
struct SourcesView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var rows: [SourceRow] = []
    @State private var windowDays: Int = 14
    @State private var grouping: Grouping = .origin

    enum Grouping: String, CaseIterable, Identifiable {
        case origin, bundle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .origin: return "按来源类型"
            case .bundle: return "按 App"
            }
        }
    }

    struct SourceRow: Identifiable, Hashable {
        let key: String
        let label: String
        let sourceName: String?
        let totalSamples: Int
        let daysActive: Int
        let lastSeenAt: Int64

        var id: String { key }
    }

    var body: some View {
        List {
            Section("窗口") {
                Stepper("过去 \(windowDays) 天", value: $windowDays, in: 7...60, step: 7)
                    .onChange(of: windowDays) {
                        Task { await refresh() }
                    }
                Picker("分组", selection: $grouping) {
                    ForEach(Grouping.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: grouping) {
                    Task { await refresh() }
                }
            }

            if rows.isEmpty {
                Section {
                    Text("尚无来源数据。先执行一次回补。").foregroundStyle(.secondary)
                }
            } else {
                Section("来源") {
                    ForEach(rows) { row in
                        SourceRowView(row: row, windowDays: windowDays)
                    }
                }
            }
        }
        .navigationTitle("数据来源")
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let earliest = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
            let earliestEpoch = Int64(earliest.timeIntervalSince1970)
            let grouping = self.grouping

            let mapped = try await environment.database.asyncRead { db -> [SourceRow] in
                let groupColumn: String = grouping == .origin
                    ? "COALESCE(source_origin, 'unknown')"
                    : "COALESCE(source_bundle_id, 'unknown')"

                let sql = """
                    SELECT
                        \(groupColumn) AS grp,
                        MIN(source_name) AS source_name,
                        COUNT(*) AS total,
                        COUNT(DISTINCT strftime('%Y-%m-%d', datetime(start_at, 'unixepoch', 'localtime'))) AS days_active,
                        MAX(ingested_at) AS last_seen_at
                    FROM health_samples_raw
                    WHERE is_deleted = 0 AND start_at >= ?
                    GROUP BY grp
                    ORDER BY total DESC
                    """
                let dbRows = try Row.fetchAll(db, sql: sql, arguments: [earliestEpoch])
                return dbRows.map { r in
                    let key: String = r["grp"] ?? "unknown"
                    let sname: String? = r["source_name"]
                    let total: Int = r["total"] ?? 0
                    let daysActive: Int = r["days_active"] ?? 0
                    let lastSeen: Int64 = r["last_seen_at"] ?? 0
                    let label: String = grouping == .origin
                        ? (SourceAttribution.Origin(rawValue: key)?.label ?? key)
                        : (sname ?? key)
                    return SourceRow(
                        key: key,
                        label: label,
                        sourceName: sname,
                        totalSamples: total,
                        daysActive: daysActive,
                        lastSeenAt: lastSeen
                    )
                }
            }
            await MainActor.run { rows = mapped }
        } catch {
            AppLogger.shared.error("Sources refresh failed: \(error.localizedDescription)")
        }
    }
}

private struct SourceRowView: View {
    let row: SourcesView.SourceRow
    let windowDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.label)
                    .font(.body.bold())
                Spacer()
                Text("\(row.totalSamples) 样本")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            if let sname = row.sourceName, sname != row.label {
                Text(sname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("活跃 \(row.daysActive) / \(windowDays) 天")
                Spacer()
                Text("上次：" + lastSeenLabel)
            }
            .font(.caption)
            .foregroundStyle(daysActiveColor)
        }
        .padding(.vertical, 2)
    }

    private var daysActiveColor: Color {
        let ratio = Double(row.daysActive) / Double(windowDays)
        if ratio >= 0.7 { return .secondary }
        if ratio >= 0.3 { return .orange }
        return .red
    }

    private var lastSeenLabel: String {
        guard row.lastSeenAt > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(row.lastSeenAt))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
