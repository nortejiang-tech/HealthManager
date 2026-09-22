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
    /// 删除计划后的撤销窗口：保留被删计划快照，底部横幅 6 秒内可撤销
    /// （与营养表「移除食材」同一交互模式，替代原先无确认直接删库）。
    @State private var pendingUndoPlan: MedicationPlan?
    @State private var undoExpiryTask: Task<Void, Never>?

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
            .safeAreaInset(edge: .bottom) { undoBanner }
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
            await MainActor.run {
                pendingUndoPlan = plan
                scheduleUndoExpiry()
            }
        } catch {
            AppLogger.shared.error("Plan delete failed: \(error.localizedDescription)")
        }
    }

    /// 撤销删除：按原 id 重新插入计划并恢复本地提醒，保证历史日志的
    /// planId 关联不断；失败则放弃撤销并重新拉取（此时计划确实已删）。
    private func undoDelete() async {
        guard let plan = pendingUndoPlan else { return }
        undoExpiryTask?.cancel()
        do {
            try await environment.database.asyncWrite { db in
                var restored = plan
                try restored.insert(db)
            }
            if plan.reminderEnabled, let id = plan.id,
               let schedule = NotificationScheduler.Schedule.fromJson(plan.scheduleJson),
               schedule.isValid {
                await NotificationScheduler.shared.schedule(
                    planId: id,
                    name: plan.name,
                    dosageMg: plan.dosageMg,
                    schedule: schedule
                )
            }
            environment.notifyLocalDataChanged()
            await MainActor.run { pendingUndoPlan = nil }
            await refresh()
        } catch {
            AppLogger.shared.error("Plan undo-delete failed: \(error.localizedDescription)")
            await MainActor.run { pendingUndoPlan = nil }
            await refresh()
        }
    }

    private func scheduleUndoExpiry() {
        undoExpiryTask?.cancel()
        undoExpiryTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { pendingUndoPlan = nil }
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if let plan = pendingUndoPlan {
            HStack(spacing: 10) {
                Text("已删除「\(plan.name)」")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("撤销") {
                    Task { await undoDelete() }
                }
                .font(.footnote.weight(.bold))
                .accessibilityIdentifier("medication-undo-delete")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider().overlay(HMColors.separator) }
            .accessibilityElement(children: .contain)
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
                        HMLoadingSkeleton(height: 72, cornerRadius: HMRadius.card)
                        HMLoadingSkeleton(height: 56, cornerRadius: HMRadius.card)
                    }
                    .padding(16)
                    .hmSurface()
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
        .hmSurface()
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
        .hmSurface(cornerRadius: HMRadius.card)
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
                        SwipeToRemoveRow(removeAccessibilityLabel: "删除计划「\(plan.name)」") {
                            PlanRow(
                                plan: plan,
                                onTaken: {
                                    Task { await onRecord(plan) }
                                },
                                onEdit: { onPlanTap(plan) }
                            )
                            .padding(.horizontal, 4)
                        } onRemove: {
                            Task { await onDeletePlan(plan) }
                        }

                        if index < plans.count - 1 {
                            Divider().overlay(HMColors.separator)
                        }
                    }
                }
                .hmSurface(cornerRadius: HMRadius.card)
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
                .hmSurface(cornerRadius: HMRadius.card)
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
        .hmSurface(cornerRadius: HMRadius.card)
    }
}

private struct PlanRow: View {
    let plan: MedicationPlan
    let onTaken: () -> Void
    let onEdit: () -> Void

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
        .accessibilityHint("点按编辑计划，左滑可删除")
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
                Text(log.action.label).font(.footnote).foregroundStyle(tone.color)
            }
            Text(dateLabel)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var dateLabel: String {
        // 行级复用缓存 formatter（AppDateFormats），此前每行每次渲染新建 DateFormatter。
        let f = AppDateFormats.shortDateTime
        if let actionAt = log.actionAt {
            return "动作 " + f.string(from: Date(timeIntervalSince1970: TimeInterval(actionAt)))
        }
        let scheduled = f.string(from: Date(timeIntervalSince1970: TimeInterval(log.scheduledAt)))
        return "计划 \(scheduled) · 动作时刻未记录"
    }

    /// ADR-002 语义色：经 EvidenceTone 统一映射，不再使用系统色。
    private var tone: HMSemanticTone {
        EvidenceTone.forMedicationAction(log.action)
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
