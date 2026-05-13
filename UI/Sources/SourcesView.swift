import SwiftUI
import GRDB

/// Shows where data comes from — attribution dashboard for PRD §4 / 来源归因.
/// Aggregates `source_coverage_daily` over the past 14 days to surface
/// "this source has been quiet for 5 days" patterns.
struct SourcesView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var rows: [SourceRow] = []
    @State private var windowDays: Int = 14

    struct SourceRow: Identifiable, Hashable {
        let sourceBundleId: String
        let sourceName: String?
        let totalSamples: Int
        let daysActive: Int
        let lastSeenAt: Int64
        let label: String

        var id: String { sourceBundleId }
    }

    var body: some View {
        List {
            Section("窗口") {
                Stepper("过去 \(windowDays) 天", value: $windowDays, in: 7...60, step: 7)
                    .onChange(of: windowDays) {
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

    @MainActor
    private func refresh() async {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            formatter.locale = Locale(identifier: "en_US_POSIX")

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let earliest = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
            let earliestKey = formatter.string(from: earliest)

            let dbRows = try environment.database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT
                        COALESCE(source_bundle_id, 'unknown') AS bid,
                        MIN(source_name) AS source_name,
                        SUM(sample_count) AS total,
                        COUNT(DISTINCT date) AS days_active,
                        MAX(last_seen_at) AS last_seen_at
                    FROM source_coverage_daily
                    WHERE date >= ?
                    GROUP BY bid
                    ORDER BY total DESC
                    """, arguments: [earliestKey])
            }

            rows = dbRows.map { r in
                let bid: String = r["bid"] ?? "unknown"
                let sname: String? = r["source_name"]
                let total: Int = r["total"] ?? 0
                let daysActive: Int = r["days_active"] ?? 0
                let lastSeen: Int64 = r["last_seen_at"] ?? 0
                let kind = SourceAttribution.classify(bundleId: bid, sourceName: sname)
                return SourceRow(
                    sourceBundleId: bid,
                    sourceName: sname,
                    totalSamples: total,
                    daysActive: daysActive,
                    lastSeenAt: lastSeen,
                    label: kind.label
                )
            }
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
            Text(row.sourceName ?? row.sourceBundleId)
                .font(.caption)
                .foregroundStyle(.secondary)
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
