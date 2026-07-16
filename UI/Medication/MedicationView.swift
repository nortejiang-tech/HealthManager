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
    @State private var isLoading: Bool = true
    @State private var hasLoadedSnapshot: Bool = false
    @State private var refreshGeneration: Int = 0
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            MedicationScreenContent(
                isLoading: isLoading,
                hasLoadedSnapshot: hasLoadedSnapshot,
                loadError: loadError,
                plans: plans,
                recentLogs: recentLogs,
                notifStatus: notifStatus,
                onAddPlan: { showingAddPlan = true },
                onPlanTap: { editingPlan = $0 },
                onRecord: { plan in
                    await recordTaken(plan)
                },
                onDeletePlan: { plan in
                    await delete(plan)
                },
                onRetry: {
                    await refresh()
                    await refreshNotifStatus()
                },
                planName: planName(for:)
            )
            .navigationTitle("用药")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddPlan = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("medication-add-plan")
                    .accessibilityLabel("新增用药计划")
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
        let (shouldShowInitialLoading, generation) = await MainActor.run {
            refreshGeneration += 1
            return (!hasLoadedSnapshot, refreshGeneration)
        }
        await MainActor.run {
            isLoading = shouldShowInitialLoading
            loadError = nil
        }

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
                guard generation == refreshGeneration else { return }
                plans = planList
                recentLogs = logList
                loadError = nil
                isLoading = false
                hasLoadedSnapshot = true
            }
        } catch {
            await MainActor.run {
                guard generation == refreshGeneration else { return }
                loadError = "用药页读取失败：\(error.localizedDescription)"
                isLoading = false
            }
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

private struct MedicationScreenContent: View {
    let isLoading: Bool
    let hasLoadedSnapshot: Bool
    let loadError: String?
    let plans: [MedicationPlan]
    let recentLogs: [MedicationLog]
    let notifStatus: UNAuthorizationStatus
    let onAddPlan: () -> Void
    let onPlanTap: (MedicationPlan) -> Void
    let onRecord: (MedicationPlan) async -> Void
    let onDeletePlan: (MedicationPlan) async -> Void
    let onRetry: () async -> Void
    let planName: (Int64?) -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(HMDateText.fullWeekday())
                    .font(.body)
                    .foregroundStyle(.secondary)

                if isLoading {
                    VStack(alignment: .leading, spacing: 12) {
                        HMLoadingSkeleton(width: 132, height: 20)
                        HMLoadingSkeleton(height: 72, cornerRadius: 16)
                        HMLoadingSkeleton(height: 56, cornerRadius: 16)
                    }
                    .padding(16)
                    .hmSurface(cornerRadius: 18)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("正在读取用药计划与动作")
                } else if hasLoadedSnapshot {
                    MedicationOverview(
                        isLoading: false,
                        hasLoadedSnapshot: true,
                        hasError: loadError != nil,
                        planCount: plans.count,
                        logCount: recentLogs.count
                    )

                    MedicationNotificationPanel(status: notifStatus)
                }

                if let loadError {
                    HMInlineRecovery(
                        title: "用药页读取失败",
                        message: "主列表数据来自数据库快照。",
                        technicalDetails: loadError,
                        actionTitle: "重试",
                        onAction: {
                            Task { await onRetry() }
                        },
                        titleAccessibilityIdentifier: "medication-load-error-title",
                        actionAccessibilityIdentifier: "medication-retry"
                    )
                }

                if hasLoadedSnapshot {
                    MedicationPlansPanel(
                        isLoading: isLoading,
                        plans: plans,
                        onAddPlan: onAddPlan,
                        onPlanTap: onPlanTap,
                        onRecord: onRecord,
                        onDeletePlan: onDeletePlan
                    )

                    MedicationLogsPanel(
                        isLoading: isLoading,
                        logs: recentLogs,
                        planName: planName
                    )
                }

            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
        .accessibilityIdentifier("medication-screen")
    }
}

private struct MedicationOverview: View {
    let isLoading: Bool
    let hasLoadedSnapshot: Bool
    let hasError: Bool
    let planCount: Int
    let logCount: Int

    var body: some View {
        HStack(spacing: 0) {
            overviewItem(
                value: hasLoadedSnapshot && !isLoading ? "\(planCount)" : "—",
                label: "个计划",
                icon: "pills.fill",
                tone: !hasLoadedSnapshot || isLoading
                    ? .neutral
                    : (hasError ? .actionRequired : .comparison)
            )
            Divider()
                .overlay(HMColors.separator)
                .padding(.vertical, 4)
            overviewItem(
                value: hasLoadedSnapshot && !isLoading ? "\(logCount)" : "—",
                label: "条最近动作",
                icon: "checkmark.circle.fill",
                tone: !hasLoadedSnapshot || isLoading
                    ? .neutral
                    : (hasError ? .actionRequired : .confirmed)
            )
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasLoadedSnapshot && !isLoading
                ? "\(planCount) 个计划，\(logCount) 条最近动作"
                : (hasError ? "用药计划与动作读取失败" : "正在读取用药计划与动作")
        )
    }

    private func overviewItem(
        value: String,
        label: String,
        icon: String,
        tone: HMSemanticTone
    ) -> some View {
        HStack(spacing: 10) {
            HMIconBadge(systemImage: icon, tone: tone, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tone.color)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MedicationNotificationPanel: View {
    let status: UNAuthorizationStatus

    private var tone: HMSemanticTone {
        switch status {
        case .denied:
            return .actionRequired
        case .authorized, .provisional, .ephemeral:
            return .confirmed
        default:
            return .neutral
        }
    }

    private var title: String {
        switch status {
        case .denied:
            return "提醒未开启"
        case .authorized, .provisional, .ephemeral:
            return "通知可用"
        default:
            return "未检测到通知权限状态"
        }
    }

    private var detail: String {
        switch status {
        case .denied:
            return "当前不会发送用药提醒，但仍可继续管理计划和记录动作。"
        case .authorized, .provisional, .ephemeral:
            return "提醒可按计划触发；实际动作仍以日志为准。"
        default:
            return "权限状态待确认，当前状态不阻塞记录。"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HMIconBadge(systemImage: notificationIcon, tone: tone)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .hmSurface(cornerRadius: 16)
    }

    private var notificationIcon: String {
        switch status {
        case .denied:
            return "bell.slash.fill"
        case .authorized, .provisional, .ephemeral:
            return "bell.fill"
        default:
            return "bell.badge"
        }
    }
}

private struct MedicationPlansPanel: View {
    let isLoading: Bool
    let plans: [MedicationPlan]
    let onAddPlan: () -> Void
    let onPlanTap: (MedicationPlan) -> Void
    let onRecord: (MedicationPlan) async -> Void
    let onDeletePlan: (MedicationPlan) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用药计划")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if isLoading {
                    HMLoadingSkeleton(width: 74, height: 16)
                } else if !plans.isEmpty {
                    Text("共 \(plans.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading {
                MedicationLoadingRows()
            } else if plans.isEmpty {
                HMEmptyState(
                    title: "尚无计划",
                    message: "添加计划后，可以在这里记录实际动作；计划时间不会被当作已服用。",
                    icon: "pills",
                    tone: .neutral,
                    primaryActionTitle: "新增计划",
                    primaryActionIcon: "plus",
                    primaryAction: onAddPlan,
                    primaryActionIdentifier: "medication-empty-add"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanRow(
                            plan: plan,
                            onTaken: {
                                Task { await onRecord(plan) }
                            },
                            onEdit: { onPlanTap(plan) },
                            onDelete: {
                                Task { await onDeletePlan(plan) }
                            }
                        )
                        .padding(.horizontal, 4)

                        if index < plans.count - 1 {
                            Divider().overlay(HMColors.separator)
                        }
                    }
                }
                .hmSurface(cornerRadius: 16)
            }
        }
    }
}

private struct MedicationLogsPanel: View {
    let isLoading: Bool
    let logs: [MedicationLog]
    let planName: (Int64?) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近日志")
                .font(.title3.weight(.semibold))

            if isLoading {
                MedicationLoadingRows()
            } else if logs.isEmpty {
                HMEmptyState(
                    title: "尚无记录",
                    message: "执行“记一次”、跳过或延后后，实际动作会显示在这里。",
                    icon: "clock.arrow.circlepath",
                    tone: .neutral
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                        LogRow(log: log, planName: planName(log.planId))
                            .padding(.horizontal, 4)

                        if index < logs.count - 1 {
                            Divider().overlay(HMColors.separator)
                        }
                    }
                }
                .hmSurface(cornerRadius: 16)
            }
        }
    }
}

private struct MedicationLoadingRows: View {
    var body: some View {
        VStack(spacing: 8) {
            HMLoadingSkeleton(height: 56)
            HMLoadingSkeleton(height: 56)
            HMLoadingSkeleton(height: 56)
        }
        .padding(12)
        .hmSurface(cornerRadius: 16)
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
                    .accessibilityIdentifier("medication-take-\(plan.id ?? -1)")
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
        .padding(.vertical, 12)
        .accessibilityIdentifier(plan.id.flatMap { "medication-plan-row-\($0)" } ?? "medication-plan-row-new")
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
        .padding(.vertical, 8)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        if let actionAt = log.actionAt {
            return "动作 " + f.string(from: Date(timeIntervalSince1970: TimeInterval(actionAt)))
        }
        let scheduled = f.string(from: Date(timeIntervalSince1970: TimeInterval(log.scheduledAt)))
        return "计划 \(scheduled) · 动作时刻未记录"
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

    private var scheduleSummary: String {
        guard reminderEnabled else {
            return "本地提醒关闭；计划仍可保存，实际动作需另行记录。"
        }

        let weekdayText: String
        if weekdays.isEmpty {
            weekdayText = "尚未选择星期"
        } else if weekdays == Set(1...7) {
            weekdayText = "每天"
        } else if weekdays == Set([2, 3, 4, 5, 6]) {
            weekdayText = "工作日"
        } else if weekdays == Set([1, 7]) {
            weekdayText = "周末"
        } else {
            weekdayText = weekdays.sorted().map(weekdayLongName).joined(separator: "、")
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let time = String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
        return "\(frequency.label) · \(weekdayText) · \(time)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HMEditorGuide(
                        title: "计划与动作分开",
                        message: "这里设置未来安排；已服、跳过或延后仍以实际动作日志为准。",
                        systemImage: "calendar.badge.clock",
                        tone: .confirmed
                    )
                }

                Section("基本信息") {
                    TextField("药物名称（如 Tirzepatide）", text: $name)
                        .accessibilityIdentifier("medication-plan-name")
                    LabeledTextField(
                        label: "剂量 mg",
                        text: $dosageMg,
                        keyboard: .decimalPad,
                        accessibilityIdentifier: "medication-plan-dosage"
                    )
                    Picker("频率", selection: $frequency) {
                        ForEach(MedicationPlan.Frequency.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .accessibilityIdentifier("medication-plan-frequency")
                }
                Section {
                    Toggle("启用本地提醒", isOn: $reminderEnabled)
                        .accessibilityIdentifier("medication-plan-reminder-enabled")
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
                        .accessibilityIdentifier("medication-plan-time")
                    }
                    if permissionDenied {
                        HMEditorCallout(
                            title: "系统通知权限未开启",
                            message: "当前不会发送提醒；可在系统“设置 → 通知 → 健康管理”中开启后再保存。",
                            tone: .actionRequired,
                            systemImage: "bell.slash.fill",
                            accessibilityIdentifier: "medication-plan-permission-denied"
                        )
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("提醒为本地通知（不联网）。修改后保存即生效；旧时间段的提醒会被替换。")
                }

                Section("计划预览") {
                    HStack(alignment: .top, spacing: 12) {
                        HMIconBadge(systemImage: "calendar", tone: .comparison, size: 38)
                        VStack(alignment: .leading, spacing: 5) {
                            HMEvidenceTag(
                                tone: .comparison,
                                text: "未来计划",
                                systemImage: "clock"
                            )
                            Text(scheduleSummary)
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("这不是服药记录；实际动作需要在用药页另行确认。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("medication-plan-preview")
                }
                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("medication-plan-notes")
                }
            }
            .navigationTitle(planToEdit == nil ? "添加用药计划" : "编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("medication-plan-cancel")
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
                    .tint(HMColors.primaryAction)
                    .accessibilityIdentifier("medication-plan-save")
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

    private func weekdayLongName(_ day: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, day - 1))]
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择星期")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                    spacing: 8
                ) {
                    weekdayButtons
                }
            } else {
                HStack(spacing: 2) {
                    weekdayButtons
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    presetButtons
                }
            } else {
                HStack(spacing: 8) {
                    presetButtons
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var weekdayButtons: some View {
        ForEach(1...7, id: \.self) { day in
            let isSelected = selected.contains(day)
            Button {
                toggle(day)
            } label: {
                Text(labelFor(day))
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(isSelected ? HMColors.confirmed : HMColors.neutral.opacity(0.12))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(isSelected ? HMColors.confirmed : HMColors.separator, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(weekdayLongName(day))
            .accessibilityValue(isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("medication-plan-weekday-\(day)")
        }
    }

    @ViewBuilder
    private var presetButtons: some View {
        presetButton("每天", days: Set(1...7))
        presetButton("工作日", days: Set([2, 3, 4, 5, 6]))
        presetButton("周末", days: Set([1, 7]))
    }

    private func presetButton(_ title: String, days: Set<Int>) -> some View {
        Button(title) { selected = days }
            .font(.footnote.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
    }

    private func labelFor(_ day: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, day - 1))]
    }

    private func weekdayLongName(_ day: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, day - 1))]
    }

    private func toggle(_ day: Int) {
        if selected.contains(day) {
            selected.remove(day)
        } else {
            selected.insert(day)
        }
    }
}

private enum MedicationPreviewFixtures {
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = Locale(identifier: "zh_CN")

        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 9, minute: 20)) ?? Date()
    }()

    static let plans: [MedicationPlan] = [
        MedicationPlan(
            id: 1,
            name: "奥美拉唑",
            dosageMg: 20,
            frequency: MedicationPlan.Frequency.weekly.rawValue,
            scheduleJson: NotificationScheduler.Schedule(weekdays: [2, 4, 6], hour: 9, minute: 0).toJson(),
            startDate: nil,
            endDate: nil,
            reminderEnabled: true,
            notes: "早餐后服用",
            createdAt: Int64(now.timeIntervalSince1970)
        ),
        MedicationPlan(
            id: 2,
            name: "维生素 D",
            dosageMg: 1,
            frequency: MedicationPlan.Frequency.weekly.rawValue,
            scheduleJson: nil,
            startDate: nil,
            endDate: nil,
            reminderEnabled: false,
            notes: nil,
            createdAt: Int64(now.timeIntervalSince1970) - 12 * 3_600
        )
    ]

    static let logs: [MedicationLog] = [
        MedicationLog(
            id: 1,
            planId: 1,
            scheduledAt: Int64(now.timeIntervalSince1970) - 3_600,
            action: .taken,
            actionAt: Int64(now.timeIntervalSince1970) - 3_600,
            dosageMg: 20,
            sideEffects: nil,
            notes: nil,
            createdAt: Int64(now.timeIntervalSince1970) - 3_600
        ),
        MedicationLog(
            id: 2,
            planId: 1,
            scheduledAt: Int64(now.timeIntervalSince1970) - 48_000,
            action: .deferred,
            actionAt: Int64(now.timeIntervalSince1970) - 48_000,
            dosageMg: nil,
            sideEffects: nil,
            notes: "忙于出差",
            createdAt: Int64(now.timeIntervalSince1970) - 48_000
        ),
        MedicationLog(
            id: 3,
            planId: 2,
            scheduledAt: Int64(now.timeIntervalSince1970) - 86_400,
            action: .skipped,
            actionAt: Int64(now.timeIntervalSince1970) - 86_400,
            dosageMg: 1,
            sideEffects: nil,
            notes: nil,
            createdAt: Int64(now.timeIntervalSince1970) - 86_400
        )
    ]
}

private func medicationPlan(for id: Int64?) -> String {
    guard let id else { return "未知计划" }
    return MedicationPreviewFixtures.plans.first { $0.id == id }?.name ?? "未知计划"
}

#Preview("Medication loaded") {
    MedicationScreenContent(
        isLoading: false,
        hasLoadedSnapshot: true,
        loadError: nil,
        plans: MedicationPreviewFixtures.plans,
        recentLogs: MedicationPreviewFixtures.logs,
        notifStatus: .authorized,
        onAddPlan: {},
        onPlanTap: { _ in },
        onRecord: { _ in },
        onDeletePlan: { _ in },
        onRetry: {},
        planName: medicationPlan(for:)
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Medication loaded (Dark)") {
    MedicationScreenContent(
        isLoading: false,
        hasLoadedSnapshot: true,
        loadError: nil,
        plans: MedicationPreviewFixtures.plans,
        recentLogs: MedicationPreviewFixtures.logs,
        notifStatus: .authorized,
        onAddPlan: {},
        onPlanTap: { _ in },
        onRecord: { _ in },
        onDeletePlan: { _ in },
        onRetry: {},
        planName: medicationPlan(for:)
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .preferredColorScheme(.dark)
}

#Preview("Medication loaded (Accessibility Large)") {
    MedicationScreenContent(
        isLoading: false,
        hasLoadedSnapshot: true,
        loadError: nil,
        plans: MedicationPreviewFixtures.plans,
        recentLogs: MedicationPreviewFixtures.logs,
        notifStatus: .authorized,
        onAddPlan: {},
        onPlanTap: { _ in },
        onRecord: { _ in },
        onDeletePlan: { _ in },
        onRetry: {},
        planName: medicationPlan(for:)
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}
