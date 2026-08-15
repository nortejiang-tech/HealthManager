import Foundation
import Combine
import GRDB

/// Singleton container wiring together the long-lived services.
/// Kept small on purpose: each feature reaches in via `@EnvironmentObject` or `AppEnvironment.shared`.
///
/// Marked `@MainActor` because `HealthKitManager` and `SyncEngine` are themselves
/// `@MainActor` (they bind to SwiftUI), so the container that owns them must be too.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let database: DatabaseManager
    let mealStore: MealStore
    let healthKitManager: HealthKitManager
    let syncEngine: SyncEngine
    let mealPersistenceCoordinator: MealPersistenceCoordinator
    let backgroundScheduler: BackgroundTaskScheduler
    let healthKitObserver: HealthKitObserver
    let backupManager: BackupManager
    @Published private(set) var localDataTick: Int = 0
    @Published private(set) var isSyncStartupReady: Bool = false
    private let aggregateProjectionVersionKey = "aggregates.projectionVersion"
    private let currentAggregateProjectionVersion = 4

    private init() {
        let database = DatabaseManager.makeDefault()
        let mealStore = MealStore(databaseManager: database)
        let healthKit = HealthKitManager(database: database)
        let syncEngine = SyncEngine(
            database: database,
            mealStore: mealStore,
            healthKitManager: healthKit,
            requiresStartupRecovery: true
        )
        let coordinator = MealPersistenceCoordinator(
            mealStore: mealStore,
            healthKitManager: healthKit
        )
        let scheduler = BackgroundTaskScheduler(syncEngine: syncEngine)
        let observer = HealthKitObserver(healthKitManager: healthKit, syncEngine: syncEngine)
        let backupManager = BackupManager(database: database)

        self.database = database
        self.mealStore = mealStore
        self.healthKitManager = healthKit
        self.syncEngine = syncEngine
        self.mealPersistenceCoordinator = coordinator
        self.backgroundScheduler = scheduler
        self.healthKitObserver = observer
        self.backupManager = backupManager
    }

    /// Called once at app launch. Side effects only — no UI work here.
    func bootstrap() {
        guard !isSyncStartupReady else { return }
        AppLogger.shared.info("AppEnvironment bootstrap; dbPath=\(database.databasePath)")

        // Every permitted BGTask identifier must have exactly one launch handler registered
        // before app launch completes. Registration is safe before recovery because the
        // scheduler and SyncEngine both keep execution closed until recovery succeeds.
        guard backgroundScheduler.registerLaunchHandlers() else {
            isSyncStartupReady = false
            AppLogger.shared.sync.error(
                "Sync startup blocked: one or more BGTask launch handlers failed to register"
            )
            return
        }

        do {
            let recovery = try SyncJobRecovery(database: database).recoverInterruptedWork()
            syncEngine.markStartupRecoveryReady()
            backgroundScheduler.enableAutomaticSyncAfterRecovery()
            isSyncStartupReady = true
            if recovery.recoveredJobCount > 0 || recovery.recoveredBackfillReportCount > 0 {
                AppLogger.shared.sync.warning(
                    "Recovered interrupted work: jobs=\(recovery.recoveredJobCount, privacy: .public), backfillReports=\(recovery.recoveredBackfillReportCount, privacy: .public)"
                )
            }
        } catch {
            isSyncStartupReady = false
            AppLogger.shared.sync.error(
                "Sync startup recovery failed; automatic sync remains disabled: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        // Schedule the first BG slots so the system has something queued even if the user
        // never opens the Sync Center.
        backgroundScheduler.scheduleIncrementalIfNeeded()
        backgroundScheduler.scheduleReconcileIfNeeded()
        // If projections are empty or the projection logic changed, catch them up so
        // the dashboard and deficit card don't wait for the next sync.
        Task { await self.backfillAggregatesIfNeeded() }
    }

    private func backfillAggregatesIfNeeded() async {
        let database = self.database
        let storedVersion = UserDefaults.standard.integer(forKey: aggregateProjectionVersionKey)
        let targetVersion = currentAggregateProjectionVersion
        let needs: Bool = (try? await database.asyncRead { db -> Bool in
            let rawCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
            // 没有原始样本时没有可投影的数据。此时绝不跑 DailyAggregator：
            // 重装后若用户恢复备份，空投影行会挡住备份值（投影表按日期 UPSERT）。
            if rawCount == 0 { return false }
            let actCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM activity_metrics_daily") ?? 0
            let bodyCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM body_metrics_daily") ?? 0
            return (actCount + bodyCount) == 0 || storedVersion < targetVersion
        }) ?? false
        guard needs else { return }
        AppLogger.shared.info("Dashboard projections need refresh — running one-shot DailyAggregator(90).")
        await syncEngine.runCatchUpAggregation(windowDays: 90)
        UserDefaults.standard.set(targetVersion, forKey: aggregateProjectionVersionKey)
    }

    /// Called by `RootView` whenever the authorization gate changes. Idempotent.
    func onAuthorizationChange() {
        guard isSyncStartupReady else { return }
        switch healthKitManager.authorizationGate {
        case .granted, .partiallyGranted:
            healthKitObserver.start()
        case .denied, .unknown, .needsRequest:
            break
        }
    }

    func notifyLocalDataChanged() {
        localDataTick &+= 1
    }
}
