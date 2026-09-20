import XCTest
import GRDB
@testable import HealthManager

/// v6_dashboard_partial_indexes 为趋势页的两个热路径查询（raw 表计数/最近摄入、
/// 未确认告警计数）提供部分索引。趋势首屏已不再读取 raw 表；回归测试保证
/// DashboardLoader 在 raw 表缺失时仍能返回全部首屏卡片。
final class DashboardIndexMigrationTests: XCTestCase {

    func test_partialIndexesExistAfterMigration() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let indexNames = try database.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(indexNames.contains("idx_raw_ingested_active"))
        XCTAssertTrue(indexNames.contains("idx_alert_unack_severity"))
    }

    func test_dashboardCountQueriesRunAgainstPartialIndexes() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        // 写入后查询计划应命中部分索引（至少不再报错且能返回正确结果）。
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at, ingested_at, is_deleted)
                VALUES ('u1', 'HKQuantityTypeIdentifierStepCount', 'quantity', 10, 'count', 1, 2, 100, 0)
                """)
            try db.execute(sql: """
                INSERT INTO missing_data_alerts
                  (date, metric, severity, message, acknowledged, created_at)
                VALUES ('2026-08-16', 'steps', 'critical', 'm', 0, 100)
                """)
        }
        let rawCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? -1
        }
        let maxIngested = try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at) FROM health_samples_raw") ?? -1
        }
        let unackCritical = try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM missing_data_alerts
                WHERE acknowledged = 0 AND severity = 'critical'
                """) ?? -1
        }
        XCTAssertEqual(rawCount, 1)
        XCTAssertEqual(maxIngested, 100)
        XCTAssertEqual(unackCritical, 1)
    }

    /// 首屏回归：日汇总已就位、raw 表被整体移除时，真实 DashboardLoader.loadSnapshot
    /// 仍须返回相同的体重等活动/身体卡片与质量数据。首屏不得依赖 health_samples_raw。
    func test_dashboardLoaderReturnsSameCardsWithoutRawTable() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: today)
        let mealTime = try XCTUnwrap(calendar.date(byAdding: .hour, value: 8, to: today))

        try database.write { db in
            try db.execute(sql: """
                INSERT INTO activity_metrics_daily
                  (date, step_count, active_energy_kcal, basal_energy_kcal,
                   resting_hr_bpm, hrv_ms, sleep_seconds, computed_at)
                VALUES (?, 8000, 320, 1450, 55, 45, 21600, ?)
                """, arguments: [todayKey, Int64(today.timeIntervalSince1970)])
            try db.execute(sql: """
                INSERT INTO body_metrics_daily
                  (date, weight_kg, bmi, computed_at)
                VALUES (?, 72.5, 23.1, ?)
                """, arguments: [todayKey, Int64(today.timeIntervalSince1970)])
            try db.execute(sql: """
                INSERT INTO meal_records
                  (meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g, created_at)
                VALUES ('breakfast', ?, 520, 30, 15, 40, ?)
                """, arguments: [
                    Int64(mealTime.timeIntervalSince1970),
                    Int64(mealTime.timeIntervalSince1970)
                ])
            try db.execute(sql: """
                INSERT INTO missing_data_alerts
                  (date, metric, severity, message, acknowledged, created_at)
                VALUES (?, 'steps', 'critical', 'm', 0, 100)
                """, arguments: [todayKey])
        }

        // 仅测试库允许 DROP TABLE：首屏一旦再碰 raw 查询，loadSnapshot 将抛 no such table。
        try database.write { db in
            try db.execute(sql: "DROP TABLE health_samples_raw")
        }

        let snapshot = try await DashboardLoader(database: database).loadSnapshot()

        XCTAssertEqual(snapshot.activity.todaySteps, 8000)
        XCTAssertEqual(snapshot.activity.todayActiveKcal, 320)
        XCTAssertEqual(snapshot.activity.last7Days.count, 1)
        XCTAssertEqual(snapshot.heart.todayRestingHR, 55)
        XCTAssertEqual(snapshot.heart.todayHRV, 45)
        XCTAssertEqual(snapshot.sleep.lastNightHours ?? 0, 6.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.body_.latestWeight, 72.5)
        XCTAssertEqual(snapshot.body_.latestBmi, 23.1)
        XCTAssertEqual(snapshot.body_.last30Days.count, 1)
        XCTAssertEqual(snapshot.diet.todayCalories, 520)
        XCTAssertEqual(snapshot.diet.hasIncompleteCalorieDays, false)
        XCTAssertEqual(snapshot.deficit.energy.intake, .complete(520))
        XCTAssertEqual(snapshot.deficit.todayBurned, 1770)
        XCTAssertEqual(snapshot.deficit.todayDeficit, 1250)
        XCTAssertEqual(snapshot.unackAlertCount, 1)
        XCTAssertEqual(snapshot.criticalAlertCount, 1)
        XCTAssertEqual(snapshot.unackMetricCount, 1)
    }
}
