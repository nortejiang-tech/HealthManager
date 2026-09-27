import Foundation
import Combine
import GRDB

struct SyncStartupLifecycle: Equatable {
    enum Event: Equatable {
        case becameActive
        case becameInactive
        case authorizationReady(Bool)
        case recoveryReady
        case recoveryFailed
    }

    enum Action: Equatable {
        case startObserver
        case runFullTypeCheck
    }

    private var isActive = false
    private var authorizationIsReady = false
    private var recoveryIsReady = false
    private var recoveryFailed = false
    private var observerStarted = false
    private var activeEpoch = 0
    private var checkedActiveEpoch: Int?

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .becameActive:
            if !isActive { activeEpoch += 1 }
            isActive = true
        case .becameInactive:
            isActive = false
        case .authorizationReady(let ready):
            authorizationIsReady = ready
        case .recoveryReady:
            recoveryIsReady = true
            recoveryFailed = false
        case .recoveryFailed:
            recoveryIsReady = false
            recoveryFailed = true
        }

        guard !recoveryFailed, recoveryIsReady, authorizationIsReady else { return [] }
        var actions: [Action] = []
        if !observerStarted {
            observerStarted = true
            actions.append(.startObserver)
        }
        if isActive, checkedActiveEpoch != activeEpoch {
            checkedActiveEpoch = activeEpoch
            actions.append(.runFullTypeCheck)
        }
        return actions
    }
}

struct StartupMaintenanceGate: Equatable {
    enum SnapshotOutcome: Equatable {
        case success
        case failure
    }

    enum Event: Equatable {
        case foregroundRequested
        case snapshotSettled(SnapshotOutcome)
        case backgroundOpportunity
    }

    enum Action: Equatable {
        case runAfterSnapshot
        case runInBackground
    }

    private(set) var isReleased = false
    private var foregroundRequested = false
    private var snapshotSettled = false

    mutating func handle(_ event: Event) -> [Action] {
        guard !isReleased else { return [] }
        switch event {
        case .foregroundRequested:
            foregroundRequested = true
        case .snapshotSettled:
            snapshotSettled = true
        case .backgroundOpportunity:
            isReleased = true
            return [.runInBackground]
        }
        if foregroundRequested && snapshotSettled {
            isReleased = true
            return [.runAfterSnapshot]
        }
        return []
    }
}

struct AggregateCatchUpDecision: Equatable {
    let hasRawSamples: Bool
    let hasActivityProjection: Bool
    let hasBodyProjection: Bool
    let storedVersion: Int
    let targetVersion: Int

    var needsCatchUp: Bool {
        guard hasRawSamples else { return false }
        return (!hasActivityProjection && !hasBodyProjection) || storedVersion < targetVersion
    }
}

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
    let personalFoodStore: PersonalFoodStore
    let personalMealTemplateStore: PersonalMealTemplateStore
    let personalCatalogStore: PersonalCatalogStore
    let healthKitManager: HealthKitManager
    let syncEngine: SyncEngine
    let mealPersistenceCoordinator: MealPersistenceCoordinator
    let backgroundScheduler: BackgroundTaskScheduler
    let healthKitObserver: HealthKitObserver
    let healthBridge: HealthBridgeManager
    let backupManager: BackupManager
    let startupMetrics: StartupMetrics
    @Published private(set) var localDataTick: Int = 0
    @Published private(set) var isSyncStartupReady: Bool = false
    private let aggregateProjectionVersionKey = "aggregates.projectionVersion"
    private let currentAggregateProjectionVersion = 4
    private var syncStartupLifecycle = SyncStartupLifecycle()
    private var startupMaintenanceGate = StartupMaintenanceGate()
    private var bridgeExportPending = false
    private var bridgeExportTask: Task<Void, Never>?

    private init() {
        let startupMetrics = StartupMetrics()
        startupMetrics.record(.environmentInitStarted)
        let database = DatabaseManager.makeDefault()
        startupMetrics.record(.databaseReady)
        let mealStore = MealStore(databaseManager: database)
        let personalFoodStore = PersonalFoodStore(databaseManager: database)
        let personalMealTemplateStore = PersonalMealTemplateStore(databaseManager: database)
        let personalCatalogStore = PersonalCatalogStore(databaseManager: database)
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
        let backupManager = BackupManager(
            database: database,
            syncRunner: syncEngine.syncRunner
        )

        self.database = database
        self.mealStore = mealStore
        self.personalFoodStore = personalFoodStore
        self.personalMealTemplateStore = personalMealTemplateStore
        self.personalCatalogStore = personalCatalogStore
        self.healthKitManager = healthKit
        self.syncEngine = syncEngine
        self.mealPersistenceCoordinator = coordinator
        self.backgroundScheduler = scheduler
        self.healthKitObserver = observer
        self.backupManager = backupManager
        self.startupMetrics = startupMetrics
        let bridge = HealthBridgeManager(database: database)
        self.healthBridge = bridge
        syncEngine.onDataSynchronized = { [weak self] in self?.requestBridgeExport() }
        startupMetrics.record(.environmentReady)
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
            driveSyncStartup(.recoveryFailed)
            startupMetrics.record(.recoveryError)
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
            driveSyncStartup(.recoveryReady)
            startupMetrics.record(.recoveryReady)
            if recovery.recoveredJobCount > 0 || recovery.recoveredBackfillReportCount > 0 {
                AppLogger.shared.sync.warning(
                    "Recovered interrupted work: jobs=\(recovery.recoveredJobCount, privacy: .public), backfillReports=\(recovery.recoveredBackfillReportCount, privacy: .public)"
                )
            }
        } catch {
            isSyncStartupReady = false
            driveSyncStartup(.recoveryFailed)
            startupMetrics.record(.recoveryError)
            AppLogger.shared.sync.error(
                "Sync startup recovery failed; automatic sync remains disabled: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        // Schedule the first BG slots so the system has something queued even if the user
        // never opens the Sync Center.
        backgroundScheduler.scheduleIncrementalIfNeeded()
        backgroundScheduler.scheduleReconcileIfNeeded()
        // Projection/catalog/Bridge maintenance is released by the first local dashboard
        // read settling. A background launch has a separate bounded opportunity and never
        // waits for SwiftUI to create the dashboard.
    }

    /// 首次启动把离线目录 41 条初始化为参考表成员；为旧配方原料补快照。
    private func seedPersonalCatalogIfNeeded() async {
        do {
            let bundled = try FoodCatalogStore.makeDefault()
            try await personalCatalogStore.seedIfNeeded(bundled: bundled)
            try await personalFoodStore.backfillRecipeSnapshots(
                bundled: bundled,
                personalCatalog: personalCatalogStore
            )
        } catch {
            AppLogger.shared.error(
                "Personal catalog seed/backfill failed: \(error.localizedDescription)"
            )
        }
    }

    private func backfillAggregatesIfNeeded() async {
        let database = self.database
        let storedVersion = UserDefaults.standard.integer(forKey: aggregateProjectionVersionKey)
        let targetVersion = currentAggregateProjectionVersion
        let decision: AggregateCatchUpDecision? = try? await database.asyncRead { db in
            let hasRaw = try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM health_samples_raw WHERE is_deleted = 0)") ?? false
            // 没有原始样本时没有可投影的数据。此时绝不跑 DailyAggregator：
            // 重装后若用户恢复备份，空投影行会挡住备份值（投影表按日期 UPSERT）。
            let hasActivity = try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM activity_metrics_daily)") ?? false
            let hasBody = try Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM body_metrics_daily)") ?? false
            return AggregateCatchUpDecision(
                hasRawSamples: hasRaw,
                hasActivityProjection: hasActivity,
                hasBodyProjection: hasBody,
                storedVersion: storedVersion,
                targetVersion: targetVersion
            )
        }
        guard decision?.needsCatchUp == true else { return }
        AppLogger.shared.info("Dashboard projections need refresh — running one-shot DailyAggregator(90).")
        if await syncEngine.runCatchUpAggregation(windowDays: 90) {
            UserDefaults.standard.set(targetVersion, forKey: aggregateProjectionVersionKey)
        }
    }

    /// Called by `RootView` whenever the authorization gate changes. Idempotent.
    func onAuthorizationChange() {
        let ready = healthKitManager.authorizationGate == .granted
            || healthKitManager.authorizationGate == .partiallyGranted
        driveSyncStartup(.authorizationReady(ready))
    }

    /// App-owned foreground lifecycle. The active intent is recorded before the async
    /// HealthKit status check, so recovery/auth completion in any order still causes exactly
    /// one full-type check for this foreground epoch.
    func applicationDidBecomeActive() async {
        requestForegroundMaintenance()
        driveSyncStartup(.authorizationReady(false))
        driveSyncStartup(.becameActive)
        await healthKitManager.refreshAuthorizationGate()
        onAuthorizationChange()
    }

    func applicationDidBecomeInactive() {
        driveSyncStartup(.becameInactive)
    }

    func applicationDidEnterBackground() async {
        releaseStartupMaintenance(for: .backgroundOpportunity)
        await backupManager.exportIfConfigured()
    }

    func initialDashboardSnapshotDidSettle(succeeded: Bool) {
        releaseStartupMaintenance(
            for: .snapshotSettled(succeeded ? .success : .failure)
        )
    }

    private func requestForegroundMaintenance() {
        bridgeExportPending = true
        releaseStartupMaintenance(for: .foregroundRequested)
        drainBridgeExportIfPossible()
    }

    private func requestBridgeExport() {
        bridgeExportPending = true
        drainBridgeExportIfPossible()
    }

    private func releaseStartupMaintenance(for event: StartupMaintenanceGate.Event) {
        let actions = startupMaintenanceGate.handle(event)
        guard let action = actions.first else { return }

        // These idempotent local migrations are deliberately detached from the initial
        // snapshot. They begin only after success/failure settles, or during a background
        // launch where no dashboard is guaranteed to exist.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.backfillAggregatesIfNeeded()
            await self.seedPersonalCatalogIfNeeded()
        }
        if action == .runInBackground || bridgeExportPending {
            bridgeExportPending = true
            drainBridgeExportIfPossible()
        }
    }

    private func drainBridgeExportIfPossible() {
        guard startupMaintenanceGate.isReleased,
              bridgeExportPending,
              bridgeExportTask == nil else { return }
        bridgeExportPending = false
        bridgeExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.healthBridge.exportIfConfigured()
            self.bridgeExportTask = nil
            self.drainBridgeExportIfPossible()
        }
    }

    private func driveSyncStartup(_ event: SyncStartupLifecycle.Event) {
        let actions = syncStartupLifecycle.handle(event)
        let startsObserver = actions.contains(.startObserver)
        let runsFullTypeCheck = actions.contains(.runFullTypeCheck)

        if startsObserver {
            healthKitObserver.start(
                initialDeliveryCoveredByImmediateFullCheck: runsFullTypeCheck
            )
        }
        if runsFullTypeCheck {
            Task { @MainActor [weak self] in
                await self?.syncEngine.runIncremental(trigger: .app)
            }
        }
    }

    func notifyLocalDataChanged() {
        localDataTick &+= 1
        requestBridgeExport()
    }
}
