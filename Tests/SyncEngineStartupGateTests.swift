import XCTest
import GRDB
@testable import HealthManager

@MainActor
final class SyncEngineStartupGateTests: XCTestCase {
    func test_allSyncEntrypointsRemainClosedUntilRecoverySucceeds() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let mealStore = MealStore(databaseManager: database)
        let healthKitManager = HealthKitManager(database: database)
        let engine = SyncEngine(
            database: database,
            mealStore: mealStore,
            healthKitManager: healthKitManager,
            requiresStartupRecovery: true
        )

        await engine.runBackfill(days: 7, trigger: .user)
        await engine.runIncremental(trigger: .timer)
        await engine.runManualSync(trigger: .user)
        await engine.runReconcile(windowDays: 7, trigger: .user)
        await engine.pushMealNutritionToHealth(requestAuthIfNeeded: true)
        await engine.runCatchUpAggregation(windowDays: 7)

        let jobCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_jobs") ?? -1
        }
        XCTAssertEqual(jobCount, 0)
        XCTAssertFalse(engine.isStartupRecoveryReady)
        XCTAssertTrue(engine.progressDescription.contains("同步启动恢复未完成"))

        engine.markStartupRecoveryReady()

        XCTAssertTrue(engine.isStartupRecoveryReady)
    }
}
