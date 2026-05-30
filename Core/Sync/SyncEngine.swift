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
    /// Bumps every time DailyAggregator finishes (sync-triggered or bootstrap catch-up).
    /// Dashboard observes this to re-fetch the projection tables.
    @Published private(set) var aggregationTick: Int = 0

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
            try? stateMachine.handle(.reset)
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
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            lastResult = result
            await rebuildDailyProjections(daysBack: 7)
            // Silent catch-up: write any not-yet-synced meal nutrition into Apple Health.
            await pushMealNutritionToHealth(requestAuthIfNeeded: false)
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
            try? stateMachine.handle(.reset)
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
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            lastResult = result
            await rebuildDailyProjections(daysBack: 7)
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
                let newId = await healthKitManager.syncMealNutrition(
                    eatenAt: meal.eatenAt,
                    calories: meal.caloriesKcal,
                    protein: meal.proteinG,
                    fat: meal.fatG,
                    carbs: meal.carbsG,
                    name: meal.notes ?? meal.mealType.label,
                    existingSyncId: meal.hkSyncId ?? "meal-\(id)"
                )
                if let newId {
                    try? await database.asyncWrite { db in
                        try db.execute(sql: "UPDATE meal_records SET hk_sync_id = ? WHERE id = ?",
                                       arguments: [newId, id])
                    }
                    synced += 1
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
    func runCatchUpAggregation(windowDays: Int) async {
        await rebuildDailyProjections(daysBack: windowDays)
    }

    private func rebuildDailyProjections(daysBack: Int) async {
        try? await dailyAggregator.rebuild(daysBack: daysBack)
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
                        """, arguments: [date, basalKcal, computedAt])

                    try db.execute(sql: """
                        INSERT INTO body_metrics_daily (date, basal_energy_kcal, computed_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(date) DO UPDATE SET
                          basal_energy_kcal = excluded.basal_energy_kcal,
                          computed_at = excluded.computed_at
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
