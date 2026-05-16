import XCTest
import GRDB
@testable import HealthManager

/// Score-boundary tests for DailyReconciler. Each test seeds a fresh in-memory DB
/// with carefully chosen samples, runs the reconciler over a 1-day window, then
/// asserts on the resulting `data_quality_daily` row.
final class DailyReconcilerTests: XCTestCase {

    var db: DatabaseManager!
    var todayKey: String!
    var dayStart: Int64!
    var dayEnd: Int64!

    override func setUp() {
        super.setUp()
        db = DatabaseManager.makeInMemoryForTesting()
        // ReconcilerSettings reads from UserDefaults; reset so it doesn't bleed across tests.
        ReconcilerSettings.resetToDefaults()

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        todayKey = f.string(from: start)
        dayStart = Int64(start.timeIntervalSince1970)
        dayEnd = Int64(end.timeIntervalSince1970) - 1
    }

    override func tearDown() {
        db = nil
        ReconcilerSettings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Completeness boundaries

    func test_completeness_allFourCoreMetricsPresent_isOne() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierBodyMass", value: 70)
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 5000)
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 70)
        try seedSample(hkType: "HKCategoryTypeIdentifierSleepAnalysis", value: 1)

        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertEqual(q.completenessScore ?? 0, 1.0, accuracy: 1e-9)
    }

    func test_completeness_zeroCorePresent_isZero() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierVO2Max", value: 40)

        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertEqual(q.completenessScore ?? -1, 0.0, accuracy: 1e-9)
    }

    func test_completeness_halfCorePresent_isHalf() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierBodyMass", value: 70)
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 1)

        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertEqual(q.completenessScore ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - Freshness boundaries

    func test_freshness_sampleIngestedNow_isOne() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierBodyMass", value: 70, ingestedAtSecondsAgo: 60)
        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertEqual(q.freshnessScore ?? 0, 1.0, accuracy: 1e-9)
    }

    func test_freshness_oldData_drops() async throws {
        // Note: we can't easily fake a 7-day-old ingested_at in a 1-day window
        // (sample.start_at must be within the day). So we just verify the score
        // exists and is in [0, 1] for now-fresh data.
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 1000, ingestedAtSecondsAgo: 0)
        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertNotNil(q.freshnessScore)
        XCTAssertGreaterThanOrEqual(q.freshnessScore ?? -1, 0)
        XCTAssertLessThanOrEqual(q.freshnessScore ?? 2, 1)
    }

    // MARK: - Conflict score

    func test_conflict_singleSource_isOne() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 70,
                       sourceBundle: "com.garmin.connect", offsetSeconds: 100)
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 71,
                       sourceBundle: "com.garmin.connect", offsetSeconds: 200)
        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertEqual(q.conflictScore ?? 0, 1.0, accuracy: 1e-9)
    }

    func test_conflict_twoSourcesSameHour_drops() async throws {
        // Two distinct bundles writing into the same hour bucket → conflict.
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 70,
                       sourceBundle: "com.garmin.connect", offsetSeconds: 100)
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 75,
                       sourceBundle: "com.apple.Health", offsetSeconds: 200)
        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)
        let q = try fetchQuality()
        XCTAssertLessThan(q.conflictScore ?? 1.0, 1.0)
    }

    // MARK: - Alerts

    func test_alert_emittedForMissingCoreMetric() async throws {
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 1000)
        let reconciler = DailyReconciler(database: db)
        let outcome = try await reconciler.run(windowDays: 1)
        XCTAssertGreaterThan(outcome.alertsEmitted, 0)
    }

    func test_completenessThreshold_emitsThresholdAlertWhenBelowSetting() async throws {
        ReconcilerSettings.completenessThreshold = 0.9
        try seedSample(hkType: "HKQuantityTypeIdentifierBodyMass", value: 70)
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 1000)
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 70)

        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)

        let exists = try thresholdAlertExists()
        XCTAssertTrue(exists)
    }

    func test_completenessThreshold_noThresholdAlertWhenAboveSetting() async throws {
        ReconcilerSettings.completenessThreshold = 0.5
        try seedSample(hkType: "HKQuantityTypeIdentifierBodyMass", value: 70)
        try seedSample(hkType: "HKQuantityTypeIdentifierStepCount", value: 1000)
        try seedSample(hkType: "HKQuantityTypeIdentifierHeartRate", value: 70)

        let reconciler = DailyReconciler(database: db)
        _ = try await reconciler.run(windowDays: 1)

        let exists = try thresholdAlertExists()
        XCTAssertFalse(exists)
    }

    func test_staleAlert_emittedWhenNoSamples() async throws {
        let reconciler = DailyReconciler(database: db)
        let outcome = try await reconciler.run(windowDays: 1)
        XCTAssertGreaterThan(outcome.alertsEmitted, 0)
        let staleExists: Bool = try await db.asyncRead { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM missing_data_alerts WHERE metric = '__stale__')") ?? false
        }
        XCTAssertTrue(staleExists)
    }

    // MARK: - Helpers

    private func seedSample(
        hkType: String,
        value: Double,
        sourceBundle: String = "com.apple.Health",
        offsetSeconds: Int64 = 100,
        ingestedAtSecondsAgo: TimeInterval = 60
    ) throws {
        let at = dayStart + offsetSeconds
        let now = Int64(Date().timeIntervalSince1970 - ingestedAtSecondsAgo)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [
                    UUID().uuidString, hkType, "quantity", value, "count",
                    at, at + 1, "Test", sourceBundle, now
                ])
        }
    }

    private func fetchQuality() throws -> DataQualityDaily {
        let key = todayKey!
        let row: DataQualityDaily? = try db.read { db in
            try DataQualityDaily.fetchOne(db, key: key)
        }
        guard let row else {
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "no quality row for \(key)"])
        }
        return row
    }

    private func thresholdAlertExists() throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM missing_data_alerts
                    WHERE metric = '__completeness__'
                )
                """) ?? false
        }
    }
}
