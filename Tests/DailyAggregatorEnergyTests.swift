import XCTest
import GRDB
@testable import HealthManager

final class DailyAggregatorEnergyTests: XCTestCase {

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

    func test_rebuildUsesWorkoutEnergyWhenActiveEnergyQuantityMissing() async throws {
        try seedWorkoutEnergy(kcal: 520, startOffset: 3_600, endOffset: 7_200)

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        XCTAssertEqual(try activeEnergy() ?? 0, 520, accuracy: 1e-9)
    }

    func test_rebuildDoesNotDoubleCountWorkoutAlreadyRepresentedByActiveEnergy() async throws {
        try seedQuantity(
            hkType: ActivityEnergyCalculator.activeEnergyType,
            value: 500,
            startOffset: 3_600,
            endOffset: 7_200
        )
        try seedWorkoutEnergy(kcal: 500, startOffset: 3_600, endOffset: 7_200)

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        XCTAssertEqual(try activeEnergy() ?? 0, 500, accuracy: 1e-9)
    }

    func test_rebuildAddsWorkoutEnergyWhenQuantityOnlyCoversNonWorkoutActivity() async throws {
        try seedQuantity(
            hkType: ActivityEnergyCalculator.activeEnergyType,
            value: 200,
            startOffset: 600,
            endOffset: 1_200
        )
        try seedWorkoutEnergy(kcal: 450, startOffset: 3_600, endOffset: 7_200)

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        XCTAssertEqual(try activeEnergy() ?? 0, 650, accuracy: 1e-9)
    }

    func test_dashboardDeficitUsesWorkoutEnergyInTotalBurn() async throws {
        try seedQuantity(
            hkType: "HKQuantityTypeIdentifierBasalEnergyBurned",
            value: 1_500,
            startOffset: 600,
            endOffset: 1_200
        )
        try seedWorkoutEnergy(kcal: 500, startOffset: 3_600, endOffset: 7_200)
        try seedMeal(kcal: 1_100, eatenOffset: 8_000)

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        let snapshot = try await DashboardLoader(database: db).loadSnapshot()
        XCTAssertEqual(snapshot.deficit.todayBurned ?? 0, 2_000, accuracy: 1e-9)
        XCTAssertEqual(snapshot.deficit.todayDeficit ?? 0, 900, accuracy: 1e-9)
    }

    func test_activityCardSeriesUsesActiveEnergyInsteadOfSteps() async throws {
        try seedQuantity(
            hkType: "HKQuantityTypeIdentifierStepCount",
            value: 12_000,
            startOffset: 600,
            endOffset: 1_200
        )
        try seedQuantity(
            hkType: ActivityEnergyCalculator.activeEnergyType,
            value: 430,
            startOffset: 1_800,
            endOffset: 2_400
        )

        let aggregator = DailyAggregator(database: db)
        try await aggregator.rebuild(daysBack: 1)

        let snapshot = try await DashboardLoader(database: db).loadSnapshot()
        XCTAssertEqual(snapshot.activity.todaySteps, 12_000)
        XCTAssertEqual(snapshot.activity.todayActiveKcal ?? 0, 430, accuracy: 1e-9)
        XCTAssertEqual(snapshot.activity.last7Days.last?.value ?? 0, 430, accuracy: 1e-9)
    }

    private func seedQuantity(
        hkType: String,
        value: Double,
        startOffset: Int64,
        endOffset: Int64,
        sourceName: String = "Health",
        sourceBundle: String = "com.apple.Health"
    ) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted, source_origin)
                VALUES (?, ?, 'quantity', ?, 'kcal', ?, ?, ?, ?, ?, 0, ?)
                """, arguments: [
                    UUID().uuidString,
                    hkType,
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

    private func seedWorkoutEnergy(
        kcal: Double,
        startOffset: Int64,
        endOffset: Int64,
        sourceName: String = "Garmin Connect",
        sourceBundle: String = "com.garmin.connect.mobile"
    ) throws {
        let extra = #"{"activityType":37,"totalEnergyKcal":\#(kcal)}"#
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted, extra_json, source_origin)
                VALUES (?, ?, 'workout', ?, 'second', ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [
                    UUID().uuidString,
                    ActivityEnergyCalculator.workoutType,
                    Double(endOffset - startOffset),
                    dayStart + startOffset,
                    dayStart + endOffset,
                    sourceName,
                    sourceBundle,
                    Int64(Date().timeIntervalSince1970),
                    extra,
                    SourceAttribution.classify(bundleId: sourceBundle, sourceName: sourceName).rawValue
                ])
        }
    }

    private func seedMeal(kcal: Double, eatenOffset: Int64) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO meal_records
                  (meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g, created_at)
                VALUES ('lunch', ?, ?, 0, 0, 0, ?)
                """, arguments: [
                    dayStart + eatenOffset,
                    kcal,
                    Int64(Date().timeIntervalSince1970)
                ])
        }
    }

    private func activeEnergy() throws -> Double? {
        try db.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT active_energy_kcal FROM activity_metrics_daily WHERE date = ?",
                arguments: [todayKey!]
            )
        }
    }
}
