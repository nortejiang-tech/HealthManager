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
    let healthKitManager: HealthKitManager
    let syncEngine: SyncEngine
    let backgroundScheduler: BackgroundTaskScheduler
    let healthKitObserver: HealthKitObserver
    @Published private(set) var localDataTick: Int = 0
    private let aggregateProjectionVersionKey = "aggregates.projectionVersion"
    private let currentAggregateProjectionVersion = 4

    private init() {
        let database = DatabaseManager.makeDefault()
        let healthKit = HealthKitManager(database: database)
        let syncEngine = SyncEngine(database: database, healthKitManager: healthKit)
        let scheduler = BackgroundTaskScheduler(syncEngine: syncEngine)
        let observer = HealthKitObserver(healthKitManager: healthKit, syncEngine: syncEngine)

        self.database = database
        self.healthKitManager = healthKit
        self.syncEngine = syncEngine
        self.backgroundScheduler = scheduler
        self.healthKitObserver = observer
    }

    /// Called once at app launch. Side effects only — no UI work here.
    func bootstrap() {
        AppLogger.shared.info("AppEnvironment bootstrap; dbPath=\(database.databasePath)")
        backgroundScheduler.registerLaunchHandlers()
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
            if rawCount == 0 { return storedVersion < targetVersion }
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
