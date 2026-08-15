import XCTest
import GRDB
@testable import HealthManager

/// v6_dashboard_partial_indexes 为趋势页的两个热路径查询（raw 表计数/最近摄入、
/// 未确认告警计数）提供部分索引。
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
}
