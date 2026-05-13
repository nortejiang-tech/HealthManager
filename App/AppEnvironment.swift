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

    private init() {
        let database = DatabaseManager.makeDefault()
        let healthKit = HealthKitManager(database: database)
        let syncEngine = SyncEngine(database: database, healthKitManager: healthKit)
        let scheduler = BackgroundTaskScheduler(syncEngine: syncEngine)

        self.database = database
        self.healthKitManager = healthKit
        self.syncEngine = syncEngine
        self.backgroundScheduler = scheduler
    }

    /// Called once at app launch. Side effects only — no UI work here.
    func bootstrap() {
        AppLogger.shared.info("AppEnvironment bootstrap; dbPath=\(database.databasePath)")
        backgroundScheduler.registerLaunchHandlers()
    }
}
