import Foundation
import Combine

/// Public surface for triggering syncs. UI calls into this; coordinators do the work.
@MainActor
final class SyncEngine: ObservableObject {

    struct LastResult: Equatable {
        let jobId: Int64
        let jobType: SyncJob.JobType
        let succeeded: Bool
        let startedAt: Date
        let endedAt: Date
        let totalSamples: Int
        let perTypeCounts: [String: Int]
        /// Per-type structured diagnostics. Auth-denied entries are present but do not
        /// affect `succeeded`. Empty on the happy path.
        let perTypeErrors: [SyncTypeError]
        let errorMessage: String?
    }

    /// Shown to the user during the wait-for-external-app phase of a manual sync.
    /// UI binds to `manualSyncPrompt` and presents an alert / sheet; tapping "已完成"
    /// (or `scenePhase` returning to `.active`) calls `acknowledgeExternalSyncDone()`.
    struct ManualSyncPrompt: Equatable {
        let title: String
        let message: String
    }

    @Published private(set) var phase: SyncStateMachine.Phase = .idle
    @Published private(set) var lastResult: LastResult?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var progressDescription: String = ""
    @Published private(set) var manualSyncPrompt: ManualSyncPrompt?

    let database: DatabaseManager
    let healthKitManager: HealthKitManager
    private(set) lazy var backfillCoordinator = BackfillCoordinator(
        healthKitManager: healthKitManager,
        database: database
    )
    private(set) lazy var incrementalCoordinator = IncrementalSyncCoordinator(
        healthKitManager: healthKitManager,
        database: database
    )
    private(set) lazy var manualCoordinator = ManualSyncCoordinator(
        incremental: incrementalCoordinator,
        database: database
    )
    private(set) lazy var dailyReconciler = DailyReconciler(database: database)
    private(set) lazy var dailyAggregator = DailyAggregator(database: database)

    private var stateMachine = SyncStateMachine()
    private var externalSyncContinuation: CheckedContinuation<Void, Never>?

    @Published private(set) var isReconciling: Bool = false
    @Published private(set) var lastReconcileOutcome: DailyReconciler.Outcome?

    init(database: DatabaseManager, healthKitManager: HealthKitManager) {
        self.database = database
        self.healthKitManager = healthKitManager
    }

    // MARK: - Backfill (F-001A)

    func runBackfill(days: Int = 30, trigger: SyncJob.Trigger = .user) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try stateMachine.handle(.startBackfill)
            phase = stateMachine.phase

            progressDescription = "回补最近 \(days) 天历史数据…"
            let result = try await backfillCoordinator.run(
                days: days,
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                }
            )

            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase
            lastResult = result
            progressDescription = "回补完成：共 \(result.totalSamples) 条样本。正在聚合…"
            await runAggregation(windowDays: max(days, 30))
            progressDescription = "回补完成：共 \(result.totalSamples) 条样本。"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "回补失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error("Backfill failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Incremental (F-001)

    func runIncremental(trigger: SyncJob.Trigger = .timer) async {
        // Single-flight: observer / BG task / timer can all converge here in quick succession.
        // Dropping concurrent calls is safe — whoever wins picks up everything new since the
        // last anchor on the next pass.
        guard !isBusy else {
            AppLogger.shared.sync.info("runIncremental skipped: busy")
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            try stateMachine.handle(.startIncremental)
            phase = stateMachine.phase
            progressDescription = "增量同步中…"

            let result = try await incrementalCoordinator.run(
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                }
            )

            try stateMachine.handle(.incrementalFinished)
            phase = stateMachine.phase
            // Round 4 will fill in real reconcile work; for now we transition through.
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            lastResult = result
            if result.succeeded {
                await runAggregation(windowDays: 7)
            }
            progressDescription = result.succeeded
                ? "增量同步完成：本轮新增 \(result.totalSamples) 条。"
                : "增量同步失败：\(result.errorMessage ?? "未知错误")"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "增量同步失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error(
                "runIncremental failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Manual one-shot (F-002)

    /// Two-pass sync framed by a user-initiated prompt: pull → ask user to open the external
    /// app → pull again. Wakes up automatically when `scenePhase` returns to `.active`.
    func runManualSync(trigger: SyncJob.Trigger = .user) async {
        guard !isBusy else {
            AppLogger.shared.sync.info("runManualSync skipped: busy")
            return
        }
        isBusy = true
        defer {
            isBusy = false
            manualSyncPrompt = nil
            // Defensive: if we exit while a continuation is pending (shouldn't happen on the
            // happy path), resume it so we don't strand the coordinator's await.
            if let cont = externalSyncContinuation {
                externalSyncContinuation = nil
                cont.resume()
            }
        }

        do {
            try stateMachine.handle(.startManual)
            phase = stateMachine.phase
            progressDescription = "手动同步：第 1 次拉取…"

            let result = try await manualCoordinator.run(
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                },
                promptForExternalSync: { [weak self] in
                    await self?.waitForExternalSync()
                }
            )

            try stateMachine.handle(.incrementalFinished)
            phase = stateMachine.phase
            try stateMachine.handle(.reconcileFinished)  // Round 4 makes this do real work.
            phase = stateMachine.phase

            lastResult = result
            if result.succeeded {
                await runAggregation(windowDays: 30)
            }
            progressDescription = result.succeeded
                ? "手动同步完成：共新增 \(result.totalSamples) 条。"
                : "手动同步失败：\(result.errorMessage ?? "未知错误")"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "手动同步失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error(
                "runManualSync failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Called by UI / scenePhase observer to tell the coordinator the user has finished
    /// (or skipped) the external-app step. Safe to call when no prompt is active — no-op.
    func acknowledgeExternalSyncDone() {
        guard let cont = externalSyncContinuation else { return }
        externalSyncContinuation = nil
        cont.resume()
    }

    /// Coordinator-facing wait. Drives the state machine into `waitingExternalSync`, exposes
    /// the prompt struct to UI, and suspends until `acknowledgeExternalSyncDone()` resumes us.
    private func waitForExternalSync() async {
        try? stateMachine.handle(.userPromptedForExternal)
        phase = stateMachine.phase

        manualSyncPrompt = ManualSyncPrompt(
            title: "请前往外部 App 同步",
            message: "打开 Garmin Connect / 米家 / 小米运动健康 等数据源 App，等待它们同步至「健康」后回到本 App 即可继续。"
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            externalSyncContinuation = cont
        }

        manualSyncPrompt = nil
        try? stateMachine.handle(.userResumedFromExternal)
        phase = stateMachine.phase
    }

    // MARK: - Reconcile (R-001)

    /// Daily data-quality reconciliation. Independent of `isBusy` because it is read-only
    /// over raw / coverage tables; safe to run alongside backfill / incremental sync.
    func runReconcile(windowDays: Int? = nil, trigger: SyncJob.Trigger = .timer) async {
        guard !isReconciling else {
            AppLogger.shared.sync.info("runReconcile skipped: already reconciling")
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        do {
            let outcome = try await dailyReconciler.run(
                windowDays: windowDays,
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                }
            )
            lastReconcileOutcome = outcome
            progressDescription = outcome.succeeded
                ? "对账完成：\(outcome.datesProcessed.count) 天 / \(outcome.alertsEmitted) 条告警。"
                : "对账失败：\(outcome.errorMessage ?? "未知错误")"
        } catch {
            AppLogger.shared.sync.error("runReconcile failed: \(error.localizedDescription, privacy: .public)")
            progressDescription = "对账失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Aggregation

    /// Roll up raw samples into the per-day projection tables consumed by the dashboard.
    /// Best-effort: failures are logged but never surface to the user as a sync failure.
    private func runAggregation(windowDays: Int) async {
        do {
            _ = try await dailyAggregator.run(windowDays: windowDays)
        } catch {
            AppLogger.shared.sync.error("DailyAggregator failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reset

    func reset() {
        try? stateMachine.handle(.reset)
        phase = stateMachine.phase
        progressDescription = ""
    }
}
