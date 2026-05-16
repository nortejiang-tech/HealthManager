import SwiftUI
import GRDB
import UserNotifications

struct MedicationView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var plans: [MedicationPlan] = []
    @State private var recentLogs: [MedicationLog] = []
    @State private var showingAddPlan: Bool = false
    @State private var editingPlan: MedicationPlan?
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            List {
                if notifStatus == .denied {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("通知未授权", systemImage: "bell.slash")
                                .font(.body.bold())
                            Text("用药提醒需要通知权限。前往「设置 → 通知 → 健康管理」开启。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("用药计划") {
                    if plans.isEmpty {
                        Text("尚无计划。点击右上 + 添加。").foregroundStyle(.secondary)
                    } else {
                        ForEach(plans) { plan in
                            PlanRow(plan: plan) {
                                Task { await recordTaken(plan) }
                            } onEdit: {
                                editingPlan = plan
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
                MedicationPlanEditView(planToEdit: nil)
            }
            .sheet(item: $editingPlan, onDismiss: { Task { await refresh() } }) { plan in
                MedicationPlanEditView(planToEdit: plan)
            }
            .task {
                await refresh()
                await refreshNotifStatus()
            }
            .refreshable { await refresh() }
        }
    }

    private func planName(for planId: Int64?) -> String {
        guard let id = planId, let plan = plans.first(where: { $0.id == id }) else { return "未知计划" }
        return plan.name
    }

    private func refresh() async {
        do {
            let (planList, logList) = try await environment.database.asyncRead { db -> ([MedicationPlan], [MedicationLog]) in
                let p = try MedicationPlan
                    .order(Column("created_at").desc)
                    .fetchAll(db)
                let l = try MedicationLog
                    .order(Column("created_at").desc)
                    .limit(20)
                    .fetchAll(db)
                return (p, l)
            }
            await MainActor.run {
                plans = planList
                recentLogs = logList
            }
        } catch {
            AppLogger.shared.error("Medication refresh failed: \(error.localizedDescription)")
        }
    }

    private func refreshNotifStatus() async {
        let status = await NotificationScheduler.shared.currentAuthorizationStatus()
        await MainActor.run { notifStatus = status }
    }

    private func recordTaken(_ plan: MedicationPlan) async {
        let log = MedicationLog(
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
            try await environment.database.asyncWrite { db in
                var l = log
                try l.insert(db)
            }
            environment.notifyLocalDataChanged()
            await refresh()
        } catch {
            AppLogger.shared.error("Med log failed: \(error.localizedDescription)")
        }
    }

    private func delete(_ plan: MedicationPlan) async {
        guard let id = plan.id else { return }
        do {
            try await environment.database.asyncWrite { db in
                _ = try MedicationPlan.deleteOne(db, key: id)
            }
            await NotificationScheduler.shared.removeAll(forPlanId: id)
            environment.notifyLocalDataChanged()
            await refresh()
        } catch {
            AppLogger.shared.error("Plan delete failed: \(error.localizedDescription)")
        }
    }
}

private struct PlanRow: View {
    let plan: MedicationPlan
    let onTaken: () -> Void
    let onEdit: () -> Void
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
                if plan.reminderEnabled, let s = NotificationScheduler.Schedule.fromJson(plan.scheduleJson) {
                    HStack(spacing: 2) {
                        Image(systemName: "bell.fill").imageScale(.small)
                        Text(scheduleLabel(s))
                    }
                    .foregroundStyle(.tint)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let notes = plan.notes, !notes.isEmpty {
                Text(notes).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            Button {
                onEdit()
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func scheduleLabel(_ s: NotificationScheduler.Schedule) -> String {
        let weekdayLabel: String
        if s.weekdays.count == 7 {
            weekdayLabel = "每天"
        } else if Set(s.weekdays) == Set([2, 3, 4, 5, 6]) {
            weekdayLabel = "工作日"
        } else {
            weekdayLabel = s.weekdays.sorted().map { weekdayShort($0) }.joined(separator: "·")
        }
        return String(format: "%@ %02d:%02d", weekdayLabel, s.hour, s.minute)
    }

    private func weekdayShort(_ w: Int) -> String {
        // 1=Sun … 7=Sat
        ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, w - 1))]
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

    let planToEdit: MedicationPlan?

    @State private var name: String = ""
    @State private var dosageMg: String = ""
    @State private var frequency: MedicationPlan.Frequency = .weekly
    @State private var notes: String = ""
    @State private var reminderEnabled: Bool = true
    @State private var weekdays: Set<Int> = [2]
    @State private var reminderTime: Date = defaultReminderTime()

    @State private var pendingPermissionRequest: Bool = false
    @State private var permissionDenied: Bool = false

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
                }
                Section {
                    Toggle("启用本地提醒", isOn: $reminderEnabled)
                        .onChange(of: reminderEnabled) { _, newValue in
                            if newValue {
                                Task { await ensurePermission() }
                            }
                        }
                    if reminderEnabled {
                        WeekdayPicker(selected: $weekdays)
                        DatePicker(
                            "时间",
                            selection: $reminderTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                    if permissionDenied {
                        Text("系统通知权限被拒绝；前往「设置 → 通知 → 健康管理」开启后再保存。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("提醒为本地通知（不联网）。修改后保存即生效；旧时间段的提醒会被替换。")
                }
                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(planToEdit == nil ? "添加用药计划" : "编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await save()
                            dismiss()
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                        || (reminderEnabled && weekdays.isEmpty)
                        || pendingPermissionRequest
                    )
                }
            }
            .task {
                applyPlanToState()
                if reminderEnabled {
                    await ensurePermission()
                }
            }
        }
    }

    private static func defaultReminderTime() -> Date {
        var comps = DateComponents()
        comps.hour = 9
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func applyPlanToState() {
        guard let p = planToEdit else { return }
        name = p.name
        if let d = p.dosageMg { dosageMg = String(d) }
        if let f = p.frequency, let parsed = MedicationPlan.Frequency(rawValue: f) {
            frequency = parsed
        }
        notes = p.notes ?? ""
        reminderEnabled = p.reminderEnabled
        if let s = NotificationScheduler.Schedule.fromJson(p.scheduleJson) {
            weekdays = Set(s.weekdays)
            var comps = DateComponents()
            comps.hour = s.hour
            comps.minute = s.minute
            if let date = Calendar.current.date(from: comps) {
                reminderTime = date
            }
        }
    }

    private func ensurePermission() async {
        await MainActor.run { pendingPermissionRequest = true }
        let granted = await NotificationScheduler.shared.requestAuthorization()
        await MainActor.run {
            pendingPermissionRequest = false
            permissionDenied = !granted
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        let schedule = NotificationScheduler.Schedule(
            weekdays: weekdays.sorted(),
            hour: hour,
            minute: minute
        )

        let scheduleJson: String? = reminderEnabled ? schedule.toJson() : nil

        let plan = MedicationPlan(
            id: planToEdit?.id,
            name: trimmedName,
            dosageMg: Double(dosageMg),
            frequency: frequency.rawValue,
            scheduleJson: scheduleJson,
            startDate: planToEdit?.startDate,
            endDate: planToEdit?.endDate,
            reminderEnabled: reminderEnabled,
            notes: notes.isEmpty ? nil : notes,
            createdAt: planToEdit?.createdAt ?? Int64(Date().timeIntervalSince1970)
        )

        do {
            let saved = try await environment.database.asyncWrite { db -> (id: Int64?, dosageMg: Double?) in
                var stored = plan
                if stored.id == nil {
                    try stored.insert(db)
                } else {
                    try stored.update(db)
                }
                return (stored.id, stored.dosageMg)
            }

            // Schedule (or clear) reminders. ID is now known.
            if let id = saved.id {
                if reminderEnabled, schedule.isValid {
                    await NotificationScheduler.shared.schedule(
                        planId: id,
                        name: trimmedName,
                        dosageMg: saved.dosageMg,
                        schedule: schedule
                    )
                } else {
                    await NotificationScheduler.shared.removeAll(forPlanId: id)
                }
            }
            environment.notifyLocalDataChanged()
        } catch {
            AppLogger.shared.error("Plan save failed: \(error.localizedDescription)")
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var selected: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Button {
                        toggle(day)
                    } label: {
                        Text(labelFor(day))
                            .font(.footnote)
                            .frame(minWidth: 32, minHeight: 32)
                            .background(selected.contains(day) ? Color.accentColor : Color.gray.opacity(0.15))
                            .foregroundStyle(selected.contains(day) ? Color.white : Color.primary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Button("每天") { selected = Set(1...7) }
                    .font(.footnote)
                Button("工作日") { selected = Set([2, 3, 4, 5, 6]) }
                    .font(.footnote)
                Button("周末") { selected = Set([1, 7]) }
                    .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func labelFor(_ day: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, day - 1))]
    }

    private func toggle(_ day: Int) {
        if selected.contains(day) {
            selected.remove(day)
        } else {
            selected.insert(day)
        }
    }
}
