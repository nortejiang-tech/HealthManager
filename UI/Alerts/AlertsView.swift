import SwiftUI
import GRDB

struct AlertsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var alerts: [MissingDataAlert] = []
    @State private var showingAcked: Bool = false
    @State private var loadError: String?
    @State private var operationError: String?

    var body: some View {
        List {
            Section {
                Toggle("显示已确认", isOn: $showingAcked)
                    .onChange(of: showingAcked) {
                        Task { await refresh() }
                    }
            }

            if let error = loadError ?? operationError {
                Section {
                    HMInlineRecovery(
                        title: loadError == nil ? "确认操作失败" : "数据提醒加载失败",
                        message: loadError == nil ? "提醒状态没有改变。可重新读取后再试。" : "现有提醒状态没有被修改。",
                        technicalDetails: error,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
            }

            if loadError == nil, operationError == nil {
                if alerts.isEmpty {
                    Section {
                        HMEmptyState(
                            title: "当前没有数据提醒",
                            message: "这表示当前筛选范围内没有需要知悉的缺失或冲突提醒，不代表健康状态结论。",
                            icon: "checkmark.bubble",
                            tone: .confirmed
                        )
                    }
                } else {
                    Section {
                        HMEditorGuide(
                            title: "提醒只描述数据状态",
                            message: "确认仅表示已知悉并隐藏该提醒，不会修改健康数据，也不会重算历史结果。",
                            systemImage: "bell.badge",
                            tone: .comparison
                        )
                    }
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
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("告警")
        .refreshable { await refresh() }
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !showingAcked, alerts.contains(where: { !$0.acknowledged }) {
                    Button("全部确认") {
                        Task { await acknowledgeAll() }
                    }
                    .tint(HMColors.comparison)
                }
            }
        }
    }

    private var groupedByDate: [(String, [MissingDataAlert])] {
        let grouped = Dictionary(grouping: alerts, by: { $0.date })
        return grouped.sorted(by: { $0.key > $1.key })
    }

    private func refresh() async {
        do {
            let includeAcked = showingAcked
            let rows = try await environment.database.asyncRead { db -> [MissingDataAlert] in
                if includeAcked {
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
            await MainActor.run {
                alerts = rows
                loadError = nil
                operationError = nil
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Alerts refresh failed: \(error.localizedDescription)")
        }
    }

    private func acknowledge(_ alert: MissingDataAlert) async {
        guard let id = alert.id else { return }
        do {
            try await environment.database.asyncWrite { db in
                try db.execute(
                    sql: "UPDATE missing_data_alerts SET acknowledged = 1 WHERE id = ?",
                    arguments: [id]
                )
            }
            await MainActor.run { operationError = nil }
            await refresh()
        } catch {
            await MainActor.run { operationError = error.localizedDescription }
            AppLogger.shared.error("Acknowledge failed: \(error.localizedDescription)")
        }
    }

    private func acknowledgeAll() async {
        do {
            try await environment.database.asyncWrite { db in
                try db.execute(sql: "UPDATE missing_data_alerts SET acknowledged = 1 WHERE acknowledged = 0")
            }
            await MainActor.run { operationError = nil }
            await refresh()
        } catch {
            await MainActor.run { operationError = error.localizedDescription }
            AppLogger.shared.error("Acknowledge all failed: \(error.localizedDescription)")
        }
    }
}

private struct AlertRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let alert: MissingDataAlert
    let onAcknowledge: () async -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    alertContent
                    actionControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    alertContent
                    Spacer(minLength: 8)
                    actionControl
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var alertContent: some View {
        HStack(alignment: .top, spacing: 12) {
            HMIconBadge(systemImage: icon, tone: tone, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DailyReconciler.humanLabel(for: alert.metric))
                        .font(.body.weight(.semibold))
                    Text(severityLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tone.color)
                }
                if let msg = alert.message {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
                Text("提醒时间：\(createdTimeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        if alert.acknowledged {
            Label("已确认", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HMColors.confirmed)
        } else {
            Button("确认") {
                Task { await onAcknowledge() }
            }
            .buttonStyle(.bordered)
            .tint(HMColors.comparison)
            .frame(minHeight: 44)
        }
    }

    private var icon: String {
        switch alert.severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private var tone: HMSemanticTone {
        switch alert.severity {
        case .critical, .warning: return .actionRequired
        case .info: return .comparison
        }
    }

    private var severityLabel: String {
        switch alert.severity {
        case .critical: return "严重"
        case .warning: return "提醒"
        case .info: return "信息"
        }
    }

    private var createdTimeText: String {
        Self.createdFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(alert.createdAt)))
    }

    private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter
    }()
}
