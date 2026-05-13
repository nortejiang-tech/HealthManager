import Foundation
import Combine

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
        // Schedule the first BG App Refresh slot so the system has something queued even
        // if the user never opens the Sync Center.
        backgroundScheduler.scheduleIncrementalIfNeeded()
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
}
