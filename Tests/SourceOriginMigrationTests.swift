import XCTest
import GRDB
@testable import HealthManager

/// v2_add_source_origin migration: verifies that existing rows get a `source_origin`
/// label that matches `SourceAttribution.classify` for the same inputs.
final class SourceOriginMigrationTests: XCTestCase {

    func test_freshDb_columnExistsAndBackfilled() throws {
        let db = DatabaseManager.makeInMemoryForTesting()

        let cases: [(uuid: String, bundle: String, name: String, expected: String)] = [
            ("u-garmin", "com.garmin.connect.mobile", "Garmin Connect", "garmin"),
            ("u-mijia", "com.xiaomi.mijia", "米家", "xiaomiMijia"),
            ("u-zepp", "com.xiaomi.hm.health", "Zepp Life", "xiaomiSports"),
            ("u-apple", "com.apple.Health", "Health", "apple"),
            ("u-huawei", "com.huawei.health", "华为运动健康", "hutool"),
            ("u-manual", "com.norte.HealthManager", "健康管理", "manual"),
            ("u-unknown", "io.totally.unknown", "RandomApp", "unknown")
        ]

        // Seed rows; migration v2 has already run on this DB so source_origin will be
        // populated *at insert time only* via the model. We want to also exercise the
        // back-fill UPDATE — so directly NULL out the column on every row, then re-run
        // a back-fill (we re-apply the same SQL the migration uses).
        try db.write { db in
            for (index, c) in cases.enumerated() {
                // Each case needs a distinct canonical-reading signature (hk_type, start_at,
                // value, unit) — v7's partial unique index now forbids two active rows sharing
                // one. These rows are only exercising source_origin back-fill, so the value is
                // irrelevant; vary start_at so each is a distinct reading.
                let s = Int64(index)
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted, source_origin)
                    VALUES (?, ?, 'quantity', 0, 'count', ?, ?, ?, ?, 0, 0, NULL)
                    """, arguments: [c.uuid, "HKQuantityTypeIdentifierBodyMass", s, s + 1, c.name, c.bundle])
            }
            // Replay the migration's back-fill UPDATE.
            try db.execute(sql: """
                UPDATE health_samples_raw
                SET source_origin = CASE
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%garmin%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%garmin%'
                        THEN 'garmin'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%mijia%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%mijia%'
                         OR COALESCE(source_name, '') LIKE '%米家%'
                        THEN 'xiaomiMijia'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%xiaomi%'
                         OR LOWER(COALESCE(source_bundle_id, '')) LIKE '%mi.fit%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%xiaomi%'
                         OR COALESCE(source_name, '') LIKE '%小米运动%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%zepp%'
                        THEN 'xiaomiSports'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE 'com.apple.%'
                         OR LOWER(COALESCE(source_name, '')) = 'health'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%apple%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%watch%'
                        THEN 'apple'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%huawei%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%huawei%'
                         OR COALESCE(source_name, '') LIKE '%华为%'
                        THEN 'hutool'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%com.norte.healthmanager%'
                        THEN 'manual'
                    ELSE 'unknown'
                END
                WHERE source_origin IS NULL
                """)
        }

        for c in cases {
            let origin: String? = try db.read { db in
                try String.fetchOne(db,
                    sql: "SELECT source_origin FROM health_samples_raw WHERE sample_uuid = ?",
                    arguments: [c.uuid])
            }
            XCTAssertEqual(origin, c.expected, "back-fill SQL must agree with classify() for \(c.bundle) / \(c.name)")
            let viaClassify = SourceAttribution.classify(bundleId: c.bundle, sourceName: c.name).rawValue
            XCTAssertEqual(origin, viaClassify, "SQL and Swift classifier must agree for \(c.bundle) / \(c.name)")
        }
    }
}
