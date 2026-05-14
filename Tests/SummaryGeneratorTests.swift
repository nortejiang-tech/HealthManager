import XCTest
import GRDB
@testable import HealthManager

/// SummaryGenerator dominant-source dedup: cumulative metrics (step count) written by
/// multiple sources for the same day must not be cross-source summed; the report should
/// pick the highest-priority source and report only its sum.
final class SummaryGeneratorTests: XCTestCase {

    func test_stepCount_dedup_prefersGarminOverApple() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = f.string(from: dayStart)

        // Garmin: 10,000 steps in 4 chunks
        // Apple Health: 8,000 steps in 4 chunks
        // Naive SUM would yield 18,000; dominant-source picks Garmin and reports 10,000.
        try db.write { db in
            for (i, chunk) in [2500, 2500, 2500, 2500].enumerated() {
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted)
                    VALUES (?, ?, 'quantity', ?, 'count', ?, ?, 'Garmin Connect', 'com.garmin.connect.mobile', ?, 0)
                    """, arguments: [
                        UUID().uuidString,
                        "HKQuantityTypeIdentifierStepCount",
                        Double(chunk),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600 + 60),
                        Int64(Date().timeIntervalSince1970)
                    ])
            }
            for (i, chunk) in [2000, 2000, 2000, 2000].enumerated() {
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted)
                    VALUES (?, ?, 'quantity', ?, 'count', ?, ?, 'iPhone', 'com.apple.Health', ?, 0)
                    """, arguments: [
                        UUID().uuidString,
                        "HKQuantityTypeIdentifierStepCount",
                        Double(chunk),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600 + 60),
                        Int64(Date().timeIntervalSince1970)
                    ])
            }
        }

        let gen = SummaryGenerator(database: db)
        let summary = try await gen.generateDaily(for: todayKey)

        guard let text = summary.summaryText else {
            return XCTFail("daily summary text was nil")
        }
        XCTAssertTrue(
            text.contains("10000") || text.contains("10,000"),
            "summary should report Garmin's 10000 steps, got: \(text)"
        )
        XCTAssertFalse(text.contains("18000"), "must not cross-source sum")
    }

    func test_emptyDay_summaryIsNonEmpty() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let gen = SummaryGenerator(database: db)
        let summary = try await gen.generateDaily(for: "2025-01-01")
        XCTAssertNotNil(summary.summaryText)
        XCTAssertFalse(summary.summaryText?.isEmpty ?? true)
    }
}
