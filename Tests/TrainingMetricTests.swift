import XCTest
import GRDB
import HealthKit
@testable import HealthManager

final class TrainingMetricTests: XCTestCase {
    func test_quantilesAndChangesRespectMissingDenominatorsAndFiniteValues() throws {
        XCTAssertEqual(try XCTUnwrap(TrainingTrendMath.percentChange(current: 240, baseline: 220)), 100 * 20 / 220, accuracy: 0.00001)
        XCTAssertEqual(TrainingTrendMath.percentChange(current: 0, baseline: 10), -100)
        XCTAssertNil(TrainingTrendMath.percentChange(current: 1, baseline: 0))
        XCTAssertNil(TrainingTrendMath.percentChange(current: .nan, baseline: 10))
        XCTAssertNil(TrainingTrendMath.quantile([], probability: 0.25))
        XCTAssertEqual(TrainingTrendMath.quantile([0, 10, 20, 30], probability: 0.25), 7.5)
        XCTAssertEqual(TrainingTrendMath.quantile([.nan, 4, .infinity], probability: 0.75), 4)
        XCTAssertNil(TrainingTrendMath.quantile([1], probability: -1))
        XCTAssertEqual(TrainingTrendMath.quantile([-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude], probability: 0.5), 0)
    }

    func test_catalogHasUniqueStableIdsAndCanonicalDashboardRoutes() {
        XCTAssertEqual(Set(TrainingMetric.allCases.map(\.id)).count, TrainingMetric.allCases.count)
        XCTAssertTrue(TrainingMetric.allCases.allSatisfy { !$0.unit.isEmpty && !$0.definition.isEmpty })
        XCTAssertEqual(MetricRoute.steps.config?.title, "步数")
        XCTAssertEqual(MetricRoute.activeKcal.config?.title, "活动能量")
        XCTAssertEqual(MetricRoute.sleep.config?.title, "睡眠")
        XCTAssertEqual(MetricRoute.diet.config?.title, MetricDetailConfig.diet.title)
        XCTAssertNotNil(TrainingMetric.weight.extendedHistoryConfig)
        XCTAssertNil(TrainingMetric.readiness.extendedHistoryConfig)
    }

    func test_rawVO2PreservesMeasurementDatesSourcesAndCanonicalUnits() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let now = Date(timeIntervalSince1970: 1_792_210_000)
        let unit = HealthKitTypeCatalog.preferredUnit(for: .vo2Max).unitString
        try database.write { db in
            for (index, source, inputUnit) in [(0, "watch-A", unit), (1, "watch-B", unit), (2, "bad-unit", "kg")] {
                let time = Int64(now.timeIntervalSince1970 - Double(index + 1) * 1000)
                try HealthSampleRaw(sampleUUID: "vo2-\(index)", hkType: HKQuantityTypeIdentifier.vo2Max.rawValue,
                    kind: .quantity, value: 40 + Double(index), unit: inputUnit, startAt: time, endAt: time,
                    sourceName: source, sourceBundleId: source, deviceName: "Watch", deviceModel: source,
                    ingestedAt: time, isDeleted: false, extraJson: nil, sourceOrigin: "apple").insert(db)
            }
            try db.execute(sql: "INSERT INTO activity_metrics_daily(date,vo2_max,computed_at) VALUES ('2026-10-01',99,1)")
        }
        let snapshot = try await TrainingSnapshotLoader.load(database: database, now: now)
        let values = snapshot.series(for: .vo2)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.map(\.source)).count, 2)
        XCTAssertEqual(values.last?.value, 40)
        XCTAssertEqual(values.last?.date.timeIntervalSince1970, now.timeIntervalSince1970 - 1000)
        XCTAssertFalse(values.contains { $0.value == 99 })
        XCTAssertTrue(TrainingText.change(values, metric: .vo2).contains("不足2次"))
    }

    func test_dailySeriesPreservesObservedZeroAndLeavesMissingDatesEmpty() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let now = Date()
        let key = TrainingCalculator.dayKey(now, .current)
        try database.write { db in
            try db.execute(sql: "INSERT INTO activity_metrics_daily(date,step_count,distance_m,computed_at) VALUES (?,0,1500,1)", arguments: [key])
        }
        let snapshot = try await TrainingSnapshotLoader.load(database: database, now: now)
        XCTAssertEqual(snapshot.series(for: .steps).count, 1)
        XCTAssertEqual(snapshot.series(for: .steps).last?.value, 0)
        XCTAssertEqual(snapshot.series(for: .distance).last?.value, 1.5)
        XCTAssertTrue(snapshot.series(for: .exercise).isEmpty)
    }
}
