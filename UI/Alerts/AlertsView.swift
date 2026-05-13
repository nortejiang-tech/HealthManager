import SwiftUI
import GRDB

struct AlertsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var alerts: [MissingDataAlert] = []
    @State private var showingAcked: Bool = false

    var body: some View {
        List {
            Section {
                Toggle("显示已确认", isOn: $showingAcked)
                    .onChange(of: showingAcked) {
                        Task { await refresh() }
                    }
            }

            if alerts.isEmpty {
                Section {
                    Text("无告警。").foregroundStyle(.secondary)
                }
            } else {
                ForEach(groupedByDate, id: \.0) { (date, items) in
                    Section(date) {
                        ForEach(items) { alert in
                            AlertRow(alert: alert) {
                                await acknowledge(alert)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("告警")
        .refreshable { await refresh() }
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !showingAcked, alerts.contains(where: { !$0.acknowledged }) {
                    Button("全部确认") {
                        Task { await acknowledgeAll() }
                    }
                }
            }
        }
    }

    private var groupedByDate: [(String, [MissingDataAlert])] {
        let grouped = Dictionary(grouping: alerts, by: { $0.date })
        return grouped.sorted(by: { $0.key > $1.key })
    }

    @MainActor
    private func refresh() async {
        do {
            let rows = try environment.database.read { db -> [MissingDataAlert] in
                if showingAcked {
                    return try MissingDataAlert
                        .order(Column("created_at").desc)
                        .limit(200)
                        .fetchAll(db)
                } else {
                    return try MissingDataAlert
                        .filter(Column("acknowledged") == false)
                        .order(Column("created_at").desc)
                        .limit(200)
                        .fetchAll(db)
                }
            }
            alerts = rows
        } catch {
            AppLogger.shared.error("Alerts refresh failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func acknowledge(_ alert: MissingDataAlert) async {
        guard let id = alert.id else { return }
        do {
            try environment.database.write { db in
                try db.execute(
                    sql: "UPDATE missing_data_alerts SET acknowledged = 1 WHERE id = ?",
                    arguments: [id]
                )
            }
            await refresh()
        } catch {
            AppLogger.shared.error("Acknowledge failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func acknowledgeAll() async {
        do {
            try environment.database.write { db in
                try db.execute(sql: "UPDATE missing_data_alerts SET acknowledged = 1 WHERE acknowledged = 0")
            }
            await refresh()
        } catch {
            AppLogger.shared.error("Acknowledge all failed: \(error.localizedDescription)")
        }
    }
}

private struct AlertRow: View {
    let alert: MissingDataAlert
    let onAcknowledge: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(DailyReconciler.humanLabel(for: alert.metric))
                    .font(.body.bold())
                Spacer()
                if alert.acknowledged {
                    Text("已确认").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("确认") {
                        Task { await onAcknowledge() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            if let msg = alert.message {
                Text(msg).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch alert.severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch alert.severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
