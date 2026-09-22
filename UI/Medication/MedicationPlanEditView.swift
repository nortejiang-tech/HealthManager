import SwiftUI

struct MedicationPlanEditView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let planToEdit: MedicationPlan?

    @State private var name: String = ""
    @State private var dosageMg: String = ""
    @State private var frequency: MedicationPlan.Frequency = .weekly
    @State private var notes: String = ""
    @State private var reminderEnabled: Bool = true
    /// 默认「每天」：多数用药为每日一次（此前默认周一，与常识相反；每周/隔周由用户主动改）。
    @State private var weekdays: Set<Int> = Set(1...7)
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
