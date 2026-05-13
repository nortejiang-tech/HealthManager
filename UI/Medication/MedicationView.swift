import SwiftUI
import GRDB

struct MedicationView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var plans: [MedicationPlan] = []
    @State private var recentLogs: [MedicationLog] = []
    @State private var showingAddPlan: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section("用药计划") {
                    if plans.isEmpty {
                        Text("尚无计划。点击右上 + 添加。").foregroundStyle(.secondary)
                    } else {
                        ForEach(plans) { plan in
                            PlanRow(plan: plan) {
                                Task { await recordTaken(plan) }
                            } onDelete: {
                                Task { await delete(plan) }
                            }
                        }
                    }
                }

                Section("最近日志") {
                    if recentLogs.isEmpty {
                        Text("尚无记录").foregroundStyle(.secondary)
                    } else {
                        ForEach(recentLogs) { log in
                            LogRow(log: log, planName: planName(for: log.planId))
                        }
                    }
                }
            }
            .navigationTitle("用药")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddPlan = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPlan, onDismiss: { Task { await refresh() } }) {
                MedicationPlanEditView()
            }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func planName(for planId: Int64?) -> String {
        guard let id = planId, let plan = plans.first(where: { $0.id == id }) else { return "未知计划" }
        return plan.name
    }

    @MainActor
    private func refresh() async {
        do {
            let (planList, logList) = try environment.database.read { db -> ([MedicationPlan], [MedicationLog]) in
                let p = try MedicationPlan
                    .order(Column("created_at").desc)
                    .fetchAll(db)
                let l = try MedicationLog
                    .order(Column("created_at").desc)
                    .limit(20)
                    .fetchAll(db)
                return (p, l)
            }
            plans = planList
            recentLogs = logList
        } catch {
            AppLogger.shared.error("Medication refresh failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func recordTaken(_ plan: MedicationPlan) async {
        var log = MedicationLog(
            id: nil,
            planId: plan.id,
            scheduledAt: Int64(Date().timeIntervalSince1970),
            action: .taken,
            actionAt: Int64(Date().timeIntervalSince1970),
            dosageMg: plan.dosageMg,
            sideEffects: nil,
            notes: nil,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        do {
            try environment.database.write { db in
                try log.insert(db)
            }
            await refresh()
        } catch {
            AppLogger.shared.error("Med log failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func delete(_ plan: MedicationPlan) async {
        guard let id = plan.id else { return }
        do {
            try environment.database.write { db in
                _ = try MedicationPlan.deleteOne(db, key: id)
            }
            await refresh()
        } catch {
            AppLogger.shared.error("Plan delete failed: \(error.localizedDescription)")
        }
    }
}

private struct PlanRow: View {
    let plan: MedicationPlan
    let onTaken: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plan.name).font(.body.bold())
                Spacer()
                Button("记一次") { onTaken() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            HStack(spacing: 12) {
                if let d = plan.dosageMg {
                    Text("\(d.formatted()) mg")
                }
                if let f = plan.frequency {
                    Text(MedicationPlan.Frequency(rawValue: f)?.label ?? f)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let notes = plan.notes, !notes.isEmpty {
                Text(notes).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct LogRow: View {
    let log: MedicationLog
    let planName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(planName).font(.body)
                Spacer()
                Text(log.action.label).font(.footnote).foregroundStyle(color)
            }
            Text(dateLabel)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        let when = log.actionAt ?? log.scheduledAt
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(when)))
    }

    private var color: Color {
        switch log.action {
        case .taken: return .green
        case .skipped: return .red
        case .deferred: return .orange
        }
    }
}

struct MedicationPlanEditView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var dosageMg: String = ""
    @State private var frequency: MedicationPlan.Frequency = .weekly
    @State private var notes: String = ""
    @State private var reminderEnabled: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    TextField("药物名称（如 Tirzepatide）", text: $name)
                    LabeledTextField(label: "剂量 mg", text: $dosageMg, keyboard: .decimalPad)
                    Picker("频率", selection: $frequency) {
                        ForEach(MedicationPlan.Frequency.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    Toggle("启用提醒", isOn: $reminderEnabled)
                }
                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("添加用药计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var plan = MedicationPlan(
            id: nil,
            name: name.trimmingCharacters(in: .whitespaces),
            dosageMg: Double(dosageMg),
            frequency: frequency.rawValue,
            scheduleJson: nil,
            startDate: nil,
            endDate: nil,
            reminderEnabled: reminderEnabled,
            notes: notes.isEmpty ? nil : notes,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        do {
            try environment.database.write { db in
                try plan.insert(db)
            }
        } catch {
            AppLogger.shared.error("Plan save failed: \(error.localizedDescription)")
        }
    }
}
