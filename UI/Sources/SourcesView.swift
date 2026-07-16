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
    @State private var loadError: String?

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

            if let loadError {
                Section {
                    HMInlineRecovery(
                        title: "来源明细加载失败",
                        message: "现有数据没有被修改。你可以在当前页面重新读取。",
                        technicalDetails: loadError,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
            } else if rows.isEmpty {
                Section {
                    HMEmptyState(
                        title: "窗口内暂无来源样本",
                        message: "这只表示所选时间范围内没有可归因的原始样本。可在同步中心回补后再回来查看。",
                        icon: "tray",
                        tone: .neutral
                    )
                }
            } else {
                Section {
                    ForEach(rows) { row in
                        SourceRowView(row: row, windowDays: windowDays)
                    }
                } header: {
                    Text("来源")
                } footer: {
                    Text("Garmin、米家等来源通过 Apple 健康样本进入；本 App 不直接连接这些服务。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
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
            await MainActor.run {
                rows = mapped
                loadError = nil
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Sources refresh failed: \(error.localizedDescription)")
        }
    }
}

private struct SourceRowView: View {
    let row: SourcesView.SourceRow
    let windowDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                HMIconBadge(
                    systemImage: isUnknown ? "questionmark.circle" : "checkmark.shield",
                    tone: isUnknown ? .actionRequired : .confirmed,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(.body.weight(.semibold))
                    Text(isUnknown ? "来源未归因" : "来源可追溯")
                        .font(.caption)
                        .foregroundStyle(isUnknown ? HMColors.actionRequired : .secondary)
                    if let sourceName = row.sourceName, sourceName != row.label {
                        Text(sourceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(row.totalSamples) 样本")
                    .font(.callout.weight(.medium).monospacedDigit())
            }

            ProgressView(value: Double(row.daysActive), total: Double(max(windowDays, 1)))
                .tint(isUnknown ? HMColors.actionRequired : HMColors.confirmed)

            HStack {
                Text("活跃 \(row.daysActive) / \(windowDays) 天")
                Spacer()
                Text("上次：" + lastSeenLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var isUnknown: Bool { row.key == "unknown" }

    private var lastSeenLabel: String {
        guard row.lastSeenAt > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(row.lastSeenAt))
        return Self.lastSeenFormatter.string(from: date)
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}
