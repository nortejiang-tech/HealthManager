import SwiftUI
import GRDB

struct SyncCenterView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var backfillDays: Int = 30
    @State private var recentReports: [BackfillReport] = []
    @State private var reportsLoaded: Bool = false
    @State private var reportsLoadError: String?

    var body: some View {
        List {
            Section("状态") {
                HStack {
                    HMEvidenceTag(
                        tone: phasePresentation.tone,
                        text: phasePresentation.label,
                        systemImage: phasePresentation.icon
                    )
                    Spacer()
                }
                if sync.isBusy {
                    ProgressView(sync.progressDescription.isEmpty ? "处理中…" : sync.progressDescription)
                } else if !sync.progressDescription.isEmpty {
                    Text(sync.progressDescription).foregroundStyle(.secondary).font(.footnote)
                }
                if sync.phase == .waitingExternalSync {
                    Text("该阶段是请外部健康 App 回写后继续，不是同步失败。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if syncPresentationFailed {
                    HMEditorCallout(
                        title: "本轮同步未完成",
                        message: "已成功写入的数据会保留；失败原因见技术信息。",
                        tone: .actionRequired,
                        systemImage: "exclamationmark.triangle.fill",
                        detail: sync.lastResult?.errorMessage ?? sync.progressDescription
                    )
                }
            }

            if let steps = manualSyncSteps {
                Section {
                    HMProvenanceRail(title: syncRailTitle, steps: steps)
                }
            }

            Section("历史回补") {
                Stepper(value: $backfillDays, in: 7...365, step: 1) {
                    Text("回溯天数：\(backfillDays)")
                }
                Button {
                    Task { await sync.runBackfill(days: backfillDays, trigger: .user); await refreshReports() }
                } label: {
                    Label("开始回补", systemImage: "arrow.clockwise.circle")
                }
                .disabled(sync.isBusy)
            }

            Section("手动一键同步") {
                Button {
                    Task { await sync.runManualSync() }
                } label: {
                    Label("立即同步", systemImage: "arrow.down.circle")
                }
                .disabled(sync.isBusy)
                Text("会先拉一次，再提示你打开 Garmin / 米家等外部 App，回到本 App 后自动续跑；并把已记录的饮食营养写回 Apple 健康（首次会请求授权）。")
                    .font(.footnote).foregroundStyle(.secondary)
                if sync.phase == .waitingExternalSync {
                    Text("等待外部 App 的行为不是失败；若已返回本 App，请点击提示完成后刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("数据对账") {
                Button {
                    Task { await sync.runReconcile(windowDays: 7, trigger: .user) }
                } label: {
                    Label(sync.isReconciling ? "对账中…" : "立即对账（7 天）", systemImage: "checkmark.seal")
                }
                .disabled(sync.isReconciling)
                if let outcome = sync.lastReconcileOutcome {
                    Text("上次：\(outcome.datesProcessed.count) 天，告警 \(outcome.alertsEmitted) 条")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let errors = sync.lastResult?.perTypeErrors, !errors.isEmpty {
                Section {
                    DisclosureGroup("同步明细（\(errors.count)）") {
                        ForEach(errors, id: \.hkType) { err in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: err.isAuthDenied
                                          ? "lock.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(err.isAuthDenied ? HMColors.comparison : HMColors.actionRequired)
                                    Text(DailyReconciler.humanLabel(for: err.hkType)).bold()
                                    Spacer()
                                    Text(err.isAuthDenied ? "未授权读取" : "失败")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(err.isAuthDenied ? HMColors.comparison : HMColors.actionRequired)
                                }
                                Text("阶段：\(err.stage.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if err.isAuthDenied {
                                    Text("该类型未读取，不影响其他已成功类型。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(err.underlying)
                                    .font(.caption)
                                    .foregroundStyle(err.isAuthDenied ? HMColors.comparison : HMColors.actionRequired)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Section("最近回补报告") {
                if !reportsLoaded, reportsLoadError == nil {
                    ProgressView("正在读取回补报告…")
                } else if reportsLoaded, recentReports.isEmpty {
                    Text("尚无报告。先执行一次回补。").foregroundStyle(.secondary)
                } else if reportsLoaded {
                    ForEach(recentReports) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.hkType).font(.system(.body, design: .monospaced))
                            HStack {
                                Text("样本：\(report.sampleCount)")
                                if report.missing { Text("缺失").foregroundStyle(HMColors.actionRequired) }
                                Text(report.status.rawValue).foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                    }
                }

                if let reportsLoadError {
                    HMInlineRecovery(
                        title: "回补报告读取失败",
                        message: reportsLoaded
                            ? "当前仍显示上一次成功读取的报告。"
                            : "尚未取得可展示的报告；不会把读取失败当作无报告。",
                        technicalDetails: reportsLoadError,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refreshReports() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("同步中心")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .task { await refreshReports() }
        .refreshable { await refreshReports() }
        .alert(
            sync.manualSyncPrompt?.title ?? "",
            isPresented: Binding(
                get: { sync.manualSyncPrompt != nil },
                set: { presented in if !presented { sync.acknowledgeExternalSyncDone() } }
            ),
            presenting: sync.manualSyncPrompt
        ) { _ in
            Button("已完成") { sync.acknowledgeExternalSyncDone() }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var phasePresentation: (label: String, tone: HMSemanticTone, icon: String) {
        if syncPresentationFailed {
            return ("未完成", .actionRequired, "exclamationmark.triangle.fill")
        }
        switch sync.phase {
        case .idle: return ("空闲", .neutral, "pause.circle")
        case .requestingAuth: return ("请求授权", .neutral, "lock.shield")
        case .backfilling: return ("回补中", .comparison, "clock.arrow.circlepath")
        case .syncingIncremental: return ("增量同步", .comparison, "arrow.down.circle")
        case .waitingExternalSync: return ("等待外部 App 同步", .comparison, "arrow.triangle.2.circlepath")
        case .syncingIncremental2: return ("二次增量", .comparison, "arrow.down.circle")
        case .reconciling: return ("对账中", .comparison, "checkmark.seal")
        case .completed: return ("完成", .confirmed, "checkmark.circle.fill")
        case .failed: return ("未完成", .actionRequired, "exclamationmark.triangle.fill")
        }
    }

    private var syncRailTitle: String {
        switch sync.phase {
        case .waitingExternalSync, .syncingIncremental2:
            return "本轮手动同步链路"
        case .completed where sync.lastResult?.jobType == .manual:
            return "本轮手动同步链路"
        default:
            return "本轮同步链路"
        }
    }

    private var manualSyncSteps: [HMProvenanceRail.Step]? {
        func step(_ title: String, _ detail: String, _ tone: HMSemanticTone, _ icon: String) -> HMProvenanceRail.Step {
            HMProvenanceRail.Step(
                title: title,
                detail: detail,
                tone: tone,
                systemImage: icon,
                accessibilityIdentifier: nil
            )
        }

        switch sync.phase {
        case .waitingExternalSync:
            return [
                step("首次拉取", "已执行", .confirmed, "arrow.down.circle"),
                step("外部回写", "等待中", .comparison, "arrow.triangle.2.circlepath"),
                step("二次拉取", "尚未执行", .neutral, "arrow.down.circle"),
                step("数据对账", "尚未执行", .neutral, "checkmark.seal")
            ]
        case .syncingIncremental2:
            return [
                step("首次拉取", "已执行", .confirmed, "arrow.down.circle"),
                step("外部回写", "已返回", .confirmed, "arrow.triangle.2.circlepath"),
                step("二次拉取", "进行中", .comparison, "arrow.down.circle"),
                step("数据对账", "尚未执行", .neutral, "checkmark.seal")
            ]
        case .completed where sync.lastResult?.jobType == .manual && sync.lastResult?.succeeded == true:
            return [
                step("首次拉取", "已执行", .confirmed, "arrow.down.circle"),
                step("外部回写", "已返回", .confirmed, "arrow.triangle.2.circlepath"),
                step("二次拉取", "已执行", .confirmed, "arrow.down.circle"),
                step("数据对账", "已执行，结果见下方", .confirmed, "checkmark.seal")
            ]
        case .completed where sync.lastResult?.succeeded == false:
            let result = sync.lastResult
            let failedTypes = result?.perTypeErrors.filter { !$0.isAuthDenied } ?? []
            let failureDetail: String
            if let first = failedTypes.first {
                failureDetail = "\(failedTypes.count) 个类型，停止于 \(first.stage.rawValue)"
            } else {
                failureDetail = result?.errorMessage ?? "作业结果标记为未完成"
            }
            return [
                step(
                    "已保留部分",
                    (result?.totalSamples ?? 0) > 0 ? "已写入 \(result?.totalSamples ?? 0) 条" : "未观察到新增写入",
                    (result?.totalSamples ?? 0) > 0 ? .confirmed : .neutral,
                    "tray.and.arrow.down"
                ),
                step("失败部分", failureDetail, .actionRequired, "exclamationmark.triangle.fill"),
                step("未执行部分", "后续阶段未确认完成", .neutral, "pause.circle")
            ]
        case .failed:
            return [
                step("当前阶段", sync.progressDescription.isEmpty ? "执行失败" : sync.progressDescription, .actionRequired, "exclamationmark.triangle.fill"),
                step("未执行部分", "后续阶段未确认完成", .neutral, "pause.circle")
            ]
        default:
            return nil
        }
    }

    private var syncPresentationFailed: Bool {
        sync.phase == .failed
            || (sync.phase == .completed && sync.lastResult?.succeeded == false)
    }

    private func refreshReports() async {
        do {
            let reports = try await environment.database.asyncRead { db -> [BackfillReport] in
                try BackfillReport
                    .order(Column("started_at").desc)
                    .limit(20)
                    .fetchAll(db)
            }
            await MainActor.run {
                recentReports = reports
                reportsLoaded = true
                reportsLoadError = nil
            }
        } catch {
            await MainActor.run {
                reportsLoadError = error.localizedDescription
            }
            AppLogger.shared.error("Reports refresh failed: \(error.localizedDescription)")
        }
    }
}
