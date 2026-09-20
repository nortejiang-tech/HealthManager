import Foundation
import Combine
import HealthKit
import GRDB

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
    private(set) var isStartupRecoveryReady: Bool

    let database: DatabaseManager
    let mealStore: MealStore
    let healthKitManager: HealthKitManager
    private(set) lazy var backfillCoordinator = BackfillCoordinator(
        healthKitManager: healthKitManager,
        database: database
    )
    private(set) lazy var incrementalCoordinator = IncrementalSyncCoordinator(
        healthKitManager: healthKitManager,
        database: database
    )
    private(set) lazy var projectionWorker = ProjectionWorker(database: database)
    private(set) lazy var syncRunner = SyncRunner(
        store: SyncWorkStore(database: database),
        projectionWorker: projectionWorker
    )
    private(set) lazy var manualCoordinator = ManualSyncCoordinator(
        database: database
    )
    private(set) lazy var dailyReconciler = DailyReconciler(database: database)
    private(set) lazy var dailyAggregator = DailyAggregator(database: database)

    private var stateMachine = SyncStateMachine()
    private var manualSyncWaiter: ManualSyncWaiter?
    private var activeIncrementalSubmissions = 0
    private var manualSessionActive = false

    @Published private(set) var isReconciling: Bool = false
    @Published private(set) var lastReconcileOutcome: DailyReconciler.Outcome?
    /// Bumps every time DailyAggregator finishes (sync-triggered or bootstrap catch-up).
    /// Dashboard observes this to re-fetch the projection tables.
    @Published private(set) var aggregationTick: Int = 0

    init(
        database: DatabaseManager,
        mealStore: MealStore,
        healthKitManager: HealthKitManager,
        requiresStartupRecovery: Bool
    ) {
        self.database = database
        self.mealStore = mealStore
        self.healthKitManager = healthKitManager
        self.isStartupRecoveryReady = !requiresStartupRecovery
    }

    func markStartupRecoveryReady() {
        isStartupRecoveryReady = true
    }

    var onDataSynchronized: (@MainActor () async -> Void)?

    // MARK: - Backfill (F-001A)

    func runBackfill(days: Int = 30, trigger: SyncJob.Trigger = .user) async {
        guard requireStartupRecoveryReady(operation: "历史回补") else { return }
        guard !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            Task { await onDataSynchronized?() }
            // Observer/foreground demand received during the exclusive legacy backfill was
            // durably queued. Give the shared runner an execution opportunity now.
            Task { @MainActor [weak self] in
                await self?.runIncremental(trigger: .timer)
            }
        }

        do {
            // After a previous run the machine sits at .completed / .failed (terminal). Reset
            // so the next .startBackfill is a legal transition from .idle.
            try? stateMachine.handle(.reset)
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
            // Refresh per-day rollups so Dashboard cards have data immediately.
            // Failures here don't roll back the sync — log and continue.
            await rebuildDailyProjections(daysBack: max(days, 30))
            progressDescription = "回补完成：共 \(result.totalSamples) 条样本。"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "回补失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error("Backfill failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Incremental (F-001)

    /// Full-catalog incremental pass. Kept source-compatible with older callers.
    func runIncremental(trigger: SyncJob.Trigger = .timer) async {
        await runIncremental(trigger: trigger, typeScope: nil)
    }

    /// Incremental pass restricted to `typeScope`.
    ///
    /// - Parameter typeScope: `nil` (default) requests the whole read catalog, which is what
    ///   foreground/auth/unlock/background/manual opportunities do. An explicit set requests
    ///   exactly those identifiers, so an observer delivery only marks the one type HealthKit
    ///   actually delivered (design §5 / C02) instead of bumping all 28 generations.
    ///   An explicitly empty set is not silently widened to the full catalog; the durable
    ///   store rejects it and no demand is recorded.
    func runIncremental(
        trigger: SyncJob.Trigger = .timer,
        typeScope: Set<String>?
    ) async {
        guard requireStartupRecoveryReady(operation: "增量同步") else { return }

        let types = typeScope ?? Set(HealthKitTypeCatalog.allReadSampleTypes.map(\.identifier))
        let demand = SyncDemand(
            types: types,
            reason: Self.syncReason(for: trigger),
            intentID: UUID()
        )

        // Backfill/manual still use their compatibility envelopes until S10. They remain
        // mutually exclusive with incremental writes, but incoming demand is persisted now
        // and is drained when the envelope releases instead of being dropped.
        if isBusy, activeIncrementalSubmissions == 0, !manualSessionActive {
            do {
                try await syncRunner.enqueue(demand)
                AppLogger.shared.sync.info("Incremental demand queued behind exclusive operation")
            } catch {
                progressDescription = "增量同步排队失败：\(error.localizedDescription)"
            }
            return
        }

        let ownsPresentation = activeIncrementalSubmissions == 0 && !manualSessionActive
        activeIncrementalSubmissions += 1
        if ownsPresentation {
            isBusy = true
            try? stateMachine.handle(.reset)
            try? stateMachine.handle(.startIncremental)
            phase = stateMachine.phase
            progressDescription = "增量同步中…"
        }
        defer {
            activeIncrementalSubmissions -= 1
            if activeIncrementalSubmissions == 0, !manualSessionActive {
                isBusy = false
                Task { await onDataSynchronized?() }
            }
        }

        do {
            let coordinator = incrementalCoordinator
            let receipt = try await syncRunner.submit(demand) { [weak self] in
                let result = try await coordinator.run(
                    trigger: trigger,
                    progress: { desc in
                        Task { @MainActor [weak self] in self?.progressDescription = desc }
                    }
                )
                return SyncRunnerSliceResult(
                    jobID: result.jobId,
                    startedAt: result.startedAt,
                    endedAt: result.endedAt,
                    perTypeCounts: result.perTypeCounts,
                    perTypeErrors: result.perTypeErrors,
                    errorMessage: result.errorMessage
                )
            }

            await publishIncrementalProjection(changedDates: receipt.changedDates)
            guard ownsPresentation else { return }
            guard let jobID = receipt.lastJobID else {
                throw SyncRunnerError.sliceLimitReached(0)
            }
            try stateMachine.handle(.incrementalFinished)
            phase = stateMachine.phase
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            let result = LastResult(
                jobId: jobID,
                jobType: .incremental,
                succeeded: receipt.firstErrorMessage == nil,
                startedAt: receipt.startedAt,
                endedAt: receipt.endedAt,
                totalSamples: receipt.perTypeCounts.values.reduce(0, +),
                perTypeCounts: receipt.perTypeCounts,
                perTypeErrors: receipt.perTypeErrors,
                errorMessage: receipt.firstErrorMessage
            )
            lastResult = result
            await pushMealNutritionToHealth(requestAuthIfNeeded: false)
            progressDescription = result.succeeded
                ? "增量同步完成：本轮新增 \(result.totalSamples) 条。"
                : "增量同步失败：\(result.errorMessage ?? "未知错误")"
        } catch {
            guard ownsPresentation else { return }
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "增量同步失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error(
                "runIncremental failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func syncReason(for trigger: SyncJob.Trigger) -> SyncReason {
        switch trigger {
        case .user: return .manual
        case .observer: return .observer
        case .bgTask: return .background
        case .timer, .app: return .foreground
        }
    }

    // MARK: - Manual one-shot (F-002)

    /// Two-pass sync framed by a user-initiated prompt: pull → ask user to open the external
    /// app → pull again. Wakes up automatically when `scenePhase` returns to `.active`.
    func runManualSync(trigger: SyncJob.Trigger = .user) async {
        guard requireStartupRecoveryReady(operation: "手动同步") else { return }
        guard !isBusy else {
            AppLogger.shared.sync.info("runManualSync skipped: busy")
            return
        }
        manualSessionActive = true
        isBusy = true
        defer {
            manualSessionActive = false
            isBusy = false
            manualSyncPrompt = nil
            if let waiter = manualSyncWaiter {
                manualSyncWaiter = nil
                Task { await waiter.resume() }
            }
        }

        do {
            try? stateMachine.handle(.reset)
            try stateMachine.handle(.startManual)
            phase = stateMachine.phase
            progressDescription = "手动同步：第 1 次拉取…"

            let result = try await manualCoordinator.run(
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                },
                runPass: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.executeManualRunnerPass()
                },
                promptForExternalSync: { [weak self] in
                    await self?.waitForExternalSync()
                }
            )

            try stateMachine.handle(.incrementalFinished)
            phase = stateMachine.phase
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            lastResult = result
            // User-initiated: also push diet nutrition to Apple Health (prompts for write
            // permission the first time).
            progressDescription = "正在把饮食营养写入 Apple 健康…"
            await pushMealNutritionToHealth(requestAuthIfNeeded: true)
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
        guard let waiter = manualSyncWaiter else { return }
        Task { await waiter.resume() }
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

        let waiter = ManualSyncWaiter()
        manualSyncWaiter = waiter
        await waiter.wait()
        if manualSyncWaiter === waiter { manualSyncWaiter = nil }

        manualSyncPrompt = nil
        try? stateMachine.handle(.userResumedFromExternal)
        phase = stateMachine.phase
    }

    private func executeManualRunnerPass() async throws -> ManualSyncPassResult {
        let demand = SyncDemand(
            types: Set(HealthKitTypeCatalog.allReadSampleTypes.map(\.identifier)),
            reason: .manual,
            intentID: UUID()
        )
        let coordinator = incrementalCoordinator
        let receipt = try await syncRunner.submit(demand) { [weak self] in
            let result = try await coordinator.run(
                trigger: .user,
                progress: { desc in
                    Task { @MainActor [weak self] in self?.progressDescription = desc }
                }
            )
            return SyncRunnerSliceResult(
                jobID: result.jobId,
                startedAt: result.startedAt,
                endedAt: result.endedAt,
                perTypeCounts: result.perTypeCounts,
                perTypeErrors: result.perTypeErrors,
                errorMessage: result.errorMessage
            )
        }
        await publishIncrementalProjection(changedDates: receipt.changedDates)
        let failedTypes = Set(receipt.perTypeErrors.map(\.hkType))
        return ManualSyncPassResult(
            perTypeCounts: receipt.perTypeCounts,
            perTypeErrors: receipt.perTypeErrors,
            successfulTypes: Set(receipt.perTypeCounts.keys).subtracting(failedTypes)
        )
    }

    // MARK: - Reconcile (R-001)

    /// Daily data-quality reconciliation. Independent of `isBusy` because it is read-only
    /// over raw / coverage tables; safe to run alongside backfill / incremental sync.
    func runReconcile(windowDays: Int? = nil, trigger: SyncJob.Trigger = .timer) async {
        guard requireStartupRecoveryReady(operation: "数据对账") else { return }
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

    // MARK: - Diet → Apple Health write-back

    /// Push app-recorded meal nutrition into Apple Health. Only meals that have macros and
    /// no prior HealthKit sync id are written — an idempotent catch-up for anything that
    /// wasn't synced inline at save time (e.g. saved before write permission was granted).
    /// Folded into incremental + manual sync so it runs on launch/foreground, on the
    /// 立即同步 button, and on observer/BG passes.
    ///
    /// - Parameter requestAuthIfNeeded: pass `true` for user-initiated syncs (may show the
    ///   permission sheet); `false` for background/launch passes (silent — only writes when
    ///   permission is already granted).
    func pushMealNutritionToHealth(requestAuthIfNeeded: Bool) async {
        guard requireStartupRecoveryReady(operation: "饮食营养同步") else { return }
        guard healthKitManager.isAvailable else { return }
        if requestAuthIfNeeded {
            _ = await healthKitManager.requestNutritionWriteAuthorization()
        }
        guard healthKitManager.isNutritionWriteAuthorized else { return }

        do {
            let meals = try await database.asyncRead { db -> [MealRecord] in
                try MealRecord
                    .filter(sql: "(calories_kcal IS NOT NULL OR protein_g IS NOT NULL OR fat_g IS NOT NULL OR carbs_g IS NOT NULL) AND hk_sync_id IS NULL")
                    .order(Column("eaten_at").desc)
                    .fetchAll(db)
            }
            guard !meals.isEmpty else { return }
            var synced = 0
            for meal in meals {
                guard let id = meal.id else { continue }
                // Deterministic per-meal id: a re-sync of the same meal always deletes-then-
                // writes the *same* Health samples, so a previously-written-but-not-persisted
                // meal can't be duplicated here (the prior `hk_sync_id` UPDATE may have failed).
                let syncResult = await healthKitManager.syncMealNutrition(
                    eatenAt: meal.eatenAt,
                    calories: meal.caloriesKcal,
                    protein: meal.proteinG,
                    fat: meal.fatG,
                    carbs: meal.carbsG,
                    name: meal.notes ?? meal.mealType.label,
                    existingSyncId: meal.hkSyncId ?? "meal-\(id)"
                )
                switch syncResult {
                case .written(let newId):
                    do {
                        _ = try await mealStore.saveSyncId(mealId: id, syncId: newId)
                        synced += 1
                    } catch {
                        AppLogger.shared.sync.error("Persist hk_sync_id failed: \(error.localizedDescription)")
                    }
                case .notWritten:
                    break
                }
            }
            if synced > 0 {
                AppLogger.shared.sync.info("Pushed \(synced) meal(s) nutrition to Apple Health")
            }
        } catch {
            AppLogger.shared.sync.info(
                "Meal nutrition push skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Aggregation catch-up

    /// One-shot aggregator pass for the dashboard's projection tables. Called from
    /// `AppEnvironment.bootstrap` when raw data exists but the daily tables are empty
    /// (e.g. user upgraded from a build that didn't run `DailyAggregator`). Bumps
    /// `aggregationTick` so observers re-fetch.
    @discardableResult
    func runCatchUpAggregation(windowDays: Int) async -> Bool {
        guard requireStartupRecoveryReady(operation: "聚合刷新") else { return false }
        return await rebuildDailyProjections(daysBack: windowDays)
    }

    @discardableResult
    private func requireStartupRecoveryReady(operation: String) -> Bool {
        guard isStartupRecoveryReady else {
            progressDescription = "同步启动恢复未完成，\(operation)已停用；请重新启动 App 后重试。"
            AppLogger.shared.sync.error(
                "\(operation, privacy: .public) blocked: startup recovery incomplete"
            )
            return false
        }
        return true
    }

    @discardableResult
    private func rebuildDailyProjections(daysBack: Int) async -> Bool {
        var rawProjectionSucceeded = true
        do {
            try await dailyAggregator.rebuild(daysBack: daysBack)
        } catch {
            rawProjectionSucceeded = false
            AppLogger.shared.sync.error(
                "Daily projection rebuild failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        await projectAppleHealthStepStatistics(daysBack: daysBack)
        await projectAppleHealthBasalEnergyStatistics(daysBack: daysBack)
        aggregationTick &+= 1
        return rawProjectionSucceeded
    }

    private func publishIncrementalProjection(changedDates: Set<String>) async {
        guard !changedDates.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = changedDates.compactMap { DashboardLoader.dateKey.date(from: $0) }.min() ?? today
        let distance = calendar.dateComponents([.day], from: earliest, to: today).day ?? 0
        let daysBack = max(1, distance + 1)
        // Exact raw aggregation already ran in ProjectionWorker. HealthKit statistics remain
        // a bounded override/fallback for the same affected span; failures preserve raw output.
        await projectAppleHealthStepStatistics(daysBack: daysBack)
        await projectAppleHealthBasalEnergyStatistics(daysBack: daysBack)
        aggregationTick &+= 1
    }

    private func projectAppleHealthStepStatistics(daysBack: Int) async {
        guard healthKitManager.isAvailable else { return }

        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let safeDays = max(daysBack, 1)
            let start = calendar.date(byAdding: .day, value: -(safeDays - 1), to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
            let stats = try await healthKitManager.fetchDailyCumulativeStatistics(
                for: .stepCount,
                unit: .count(),
                from: start,
                to: end
            )
            let computedAt = Int64(Date().timeIntervalSince1970)
            let rows: [(String, Int?)] = stats.map { stat in
                let rounded = stat.value.map { Int($0.rounded()) }
                let stepCount = (rounded ?? 0) > 0 ? rounded : nil
                return (DashboardLoader.dateKey.string(from: calendar.startOfDay(for: stat.startDate)), stepCount)
            }

            try await database.asyncWrite { db in
                for (date, stepCount) in rows {
                    // No system statistic for this day → keep whatever DailyAggregator
                    // already projected. Never NULL out an aggregated value.
                    guard let stepCount else { continue }
                    try db.execute(sql: """
                        INSERT INTO activity_metrics_daily (date, step_count, computed_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(date) DO UPDATE SET
                          step_count = excluded.step_count,
                          computed_at = excluded.computed_at
                        WHERE activity_metrics_daily.step_count IS NOT excluded.step_count
                        """, arguments: [date, stepCount, computedAt])
                }
            }
        } catch {
            AppLogger.shared.sync.info(
                "Apple Health step statistics projection skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func projectAppleHealthBasalEnergyStatistics(daysBack: Int) async {
        guard healthKitManager.isAvailable else { return }

        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let safeDays = max(daysBack, 1)
            let start = calendar.date(byAdding: .day, value: -(safeDays - 1), to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
            let stats = try await healthKitManager.fetchDailyCumulativeStatistics(
                for: .basalEnergyBurned,
                unit: .kilocalorie(),
                from: start,
                to: end
            )
            let computedAt = Int64(Date().timeIntervalSince1970)
            let rows: [(String, Double?)] = stats.map { stat in
                let basal = stat.value.map { max(0, $0) }
                let basalKcal = (basal ?? 0) > 0 ? basal : nil
                return (DashboardLoader.dateKey.string(from: calendar.startOfDay(for: stat.startDate)), basalKcal)
            }

            try await database.asyncWrite { db in
                for (date, basalKcal) in rows {
                    // No system statistic for this day → keep whatever DailyAggregator
                    // already projected. Never NULL out an aggregated value.
                    guard let basalKcal else { continue }
                    try db.execute(sql: """
                        INSERT INTO activity_metrics_daily (date, basal_energy_kcal, computed_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(date) DO UPDATE SET
                          basal_energy_kcal = excluded.basal_energy_kcal,
                          computed_at = excluded.computed_at
                        WHERE activity_metrics_daily.basal_energy_kcal IS NOT excluded.basal_energy_kcal
                        """, arguments: [date, basalKcal, computedAt])

                    try db.execute(sql: """
                        INSERT INTO body_metrics_daily (date, basal_energy_kcal, computed_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(date) DO UPDATE SET
                          basal_energy_kcal = excluded.basal_energy_kcal,
                          computed_at = excluded.computed_at
                        WHERE body_metrics_daily.basal_energy_kcal IS NOT excluded.basal_energy_kcal
                        """, arguments: [date, basalKcal, computedAt])
                }
            }
        } catch {
            AppLogger.shared.sync.info(
                "Apple Health basal-energy statistics projection skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Reset

    func reset() {
        try? stateMachine.handle(.reset)
        phase = stateMachine.phase
        progressDescription = ""
    }
}
