import XCTest
import GRDB
@testable import HealthManager

final class DailyAggregatorSleepTests: XCTestCase {

    private var db: DatabaseManager!
    private var todayKey: String!
    private var dayStart: Int64!

    override func setUp() {
        super.setUp()
        db = DatabaseManager.makeInMemoryForTesting()

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        todayKey = formatter.string(from: start)
        dayStart = Int64(start.timeIntervalSince1970)
    }

    override func tearDown() {
        db = nil
        todayKey = nil
        dayStart = nil
        super.tearDown()
    }

    func test_rebuildClearsHistoricalSleepEfficiencyAndKeepsAsleepSeconds() async throws {
        let expectedAsleepSeconds = 1_800

        try seedHistoricalSleepAggregate(
            sleepEfficiency: 74.2,
            sleepSeconds: 9_999
        )
        try seedSleepSample(
            value: 0,
            startOffset: 600,
            endOffset: 3_600,
            sourceName: "Device A",
            sourceBundle: "com.example.device"
        )
        try seedSleepSample(
            value: 2,
            startOffset: 3_600,
            endOffset: 4_200,
            sourceName: "Device A",
            sourceBundle: "com.example.device"
        )
        try seedSleepSample(
            value: 1,
            startOffset: 4_200,
            endOffset: 6_000,
            sourceName: "Device A",
            sourceBundle: "com.example.device"
        )

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT sleep_seconds, sleep_efficiency FROM activity_metrics_daily WHERE date = ?", arguments: [todayKey!])!
            XCTAssertEqual(row["sleep_seconds"] as Int?, expectedAsleepSeconds)
            XCTAssertNil(row["sleep_efficiency"] as Double?)
        }
    }

    func test_dashboardLoaderStillReadsSleepHoursWhenEfficiencyCleared() async throws {
        let expectedAsleepSeconds = 3_600

        try seedHistoricalSleepAggregate(
            sleepEfficiency: 61.0,
            sleepSeconds: 7_200
        )
        try seedSleepSample(
            value: 0,
            startOffset: 600,
            endOffset: 2_400,
            sourceName: "Apple Watch",
            sourceBundle: "com.apple.watch"
        )
        try seedSleepSample(
            value: 2,
            startOffset: 2_400,
            endOffset: 2_700,
            sourceName: "Apple Watch",
            sourceBundle: "com.apple.watch"
        )
        try seedSleepSample(
            value: 1,
            startOffset: 2_700,
            endOffset: 6_300,
            sourceName: "Apple Watch",
            sourceBundle: "com.apple.watch"
        )

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        let snapshot = try await DashboardLoader(database: db).loadSnapshot()
        let expectedHours = Double(expectedAsleepSeconds) / 3600.0
        XCTAssertEqual(snapshot.sleep.lastNightHours ?? 0, expectedHours, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sleep.last7Days.last?.value ?? 0, expectedHours, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sleep.last7Days.count, 1)
    }

    private func seedSleepSample(
        value: Double,
        startOffset: Int64,
        endOffset: Int64,
        sourceName: String,
        sourceBundle: String
    ) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted, source_origin)
                VALUES (?, ?, 'category', ?, 'state', ?, ?, ?, ?, ?, 0, ?)
                """, arguments: [
                    UUID().uuidString,
                    "HKCategoryTypeIdentifierSleepAnalysis",
                    value,
                    dayStart + startOffset,
                    dayStart + endOffset,
                    sourceName,
                    sourceBundle,
                    Int64(Date().timeIntervalSince1970),
                    SourceAttribution.classify(bundleId: sourceBundle, sourceName: sourceName).rawValue
                ])
        }
    }

    private func seedHistoricalSleepAggregate(sleepEfficiency: Double, sleepSeconds: Int64) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO activity_metrics_daily
                  (date, sleep_seconds, sleep_efficiency, computed_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [todayKey, sleepSeconds, sleepEfficiency, Int64(Date().timeIntervalSince1970)])
        }
    }
}
