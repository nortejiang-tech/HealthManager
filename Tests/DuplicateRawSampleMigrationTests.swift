import XCTest
import GRDB
@testable import HealthManager

/// v7_collapse_duplicate_raw_samples migration: verifies that clearly-duplicate raw samples
/// (same `hk_type` + `start_at` + `value` + `unit`, written by two source apps — e.g. 小米体重秤
/// and 小米运动/Zepp both mirroring the same weigh-in into Apple Health) are collapsed to a
/// single active row, and that the partial unique index stops a fresh sync from re-recording them.
final class DuplicateRawSampleMigrationTests: XCTestCase {

    private static let bodyMass = "HKQuantityTypeIdentifierBodyMass"

    /// Mirrors `DatabaseManager.makeInMemoryForTesting` but lets us stop at a migration
    /// version so we can seed duplicates *before* v7 runs.
    private func makePool(upTo migration: String? = nil) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-dedup-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        var migrator = Migrations.makeMigrator()
        if let migration {
            try migrator.migrate(pool, upTo: migration)
        } else {
            try migrator.migrate(pool)
        }
        return pool
    }

    private func seedReading(
        pool: DatabasePool,
        uuid: String,
        startAt: Int64,
        value: Double,
        origin: String,
        ingestedAt: Int64
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted, source_origin)
                VALUES (?, ?, 'quantity', ?, 'kg', ?, ?, NULL, NULL, ?, 0, ?)
                """, arguments: [uuid, Self.bodyMass, value, startAt, startAt, ingestedAt, origin])
        }
    }

    private func activeOrigins(pool: DatabasePool, startAt: Int64) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT source_origin FROM health_samples_raw
                WHERE is_deleted = 0 AND hk_type = ? AND start_at = ?
                ORDER BY sample_uuid ASC
                """, arguments: [Self.bodyMass, startAt])
        }
    }

    private func activeCount(pool: DatabasePool) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? -1
        }
    }

    // MARK: - Cleanup of existing duplicates

    func test_migration_collapsesMultiSourceSameReading_keepingDominantSource() throws {
        // Migrate only up to v6 so v7's cleanup hasn't wiped the duplicates yet.
        let pool = try makePool(upTo: "v6_dashboard_partial_indexes")
        let s = Int64(1_700_000_000)
        // Same physical weigh-in written by three sources (different UUIDs, same signature).
        try seedReading(pool: pool, uuid: "u-mijia",   startAt: s, value: 82.8, origin: "xiaomiMijia",   ingestedAt: 100)
        try seedReading(pool: pool, uuid: "u-sports",  startAt: s, value: 82.8, origin: "xiaomiSports",  ingestedAt: 200)
        try seedReading(pool: pool, uuid: "u-garmin",  startAt: s, value: 82.8, origin: "garmin",        ingestedAt: 300)

        // Run v7.
        try Migrations.run(on: pool)

        // Exactly one active row survives; the dominant source (garmin, priority 100) is kept.
        let origins = try activeOrigins(pool: pool, startAt: s)
        XCTAssertEqual(origins, ["garmin"], "only the highest-priority source should remain active")
        XCTAssertEqual(try activeCount(pool: pool), 1, "the other two rows must be soft-deleted")
    }

    func test_migration_tieBreakKeepsEarliestIngestedRow() throws {
        let pool = try makePool(upTo: "v6_dashboard_partial_indexes")
        let s = Int64(1_700_000_000)
        // Both Xiaomi sources share the same priority (30) — the earlier-ingested row wins.
        try seedReading(pool: pool, uuid: "u-mijia",  startAt: s, value: 82.8, origin: "xiaomiMijia",  ingestedAt: 200)
        try seedReading(pool: pool, uuid: "u-sports", startAt: s, value: 82.8, origin: "xiaomiSports", ingestedAt: 100)

        try Migrations.run(on: pool)

        let origins = try activeOrigins(pool: pool, startAt: s)
        XCTAssertEqual(origins, ["xiaomiSports"], "earlier-ingested row (ingested_at=100) wins the tie")
    }

    func test_migration_keepsDistinctReadingsIntact() throws {
        let pool = try makePool(upTo: "v6_dashboard_partial_indexes")
        // Two *genuinely different* weigh-ins (different timestamp) must both survive.
        try seedReading(pool: pool, uuid: "u-a", startAt: 1_700_000_000, value: 82.8, origin: "xiaomiSports", ingestedAt: 100)
        try seedReading(pool: pool, uuid: "u-b", startAt: 1_700_003_600, value: 82.5, origin: "xiaomiMijia",   ingestedAt: 200)

        try Migrations.run(on: pool)

        XCTAssertEqual(try activeCount(pool: pool), 2, "different timestamps are not duplicates and must be kept")
    }

    // MARK: - ROUND-tolerance (v8) handles cross-app float representation noise

    func test_migration_collapsesFloatNoiseSameReading() throws {
        // Two apps record the SAME weigh-in but store slightly different doubles at the
        // float-representation level (e.g. 82.84999847 vs 82.85, both displayed as 82.8).
        // v7's exact-double equality misses this; v8's ROUND(value,3) must collapse it.
        let pool = try makePool(upTo: "v6_dashboard_partial_indexes")
        let s = Int64(1_700_000_000)
        try seedReading(pool: pool, uuid: "u-sports", startAt: s, value: 82.84999847412109, origin: "xiaomiSports", ingestedAt: 100)
        try seedReading(pool: pool, uuid: "u-mijia",  startAt: s, value: 82.84999999999999, origin: "xiaomiMijia",  ingestedAt: 200)

        try Migrations.run(on: pool)

        // Same priority (both xiaomi = 30) → earlier-ingested (sports) wins the tie.
        XCTAssertEqual(try activeOrigins(pool: pool, startAt: s), ["xiaomiSports"])
        XCTAssertEqual(try activeCount(pool: pool), 1, "ROUND(,3) must collapse float-noise duplicates to one")
    }

    func test_uniqueIndex_blocksReRecordingFloatNoiseDuplicate() throws {
        let pool = try makePool()
        let s = Int64(1_700_000_000)
        try seedReading(pool: pool, uuid: "u-first", startAt: s, value: 82.84999847412109, origin: "xiaomiSports", ingestedAt: 100)

        // A fresh sync re-fetches the same physical reading with a slightly different double.
        XCTAssertThrowsError(try seedReading(
            pool: pool, uuid: "u-dup", startAt: s, value: 82.84999999999999, origin: "xiaomiMijia", ingestedAt: 200
        ), "a second active row rounding to the same reading must be rejected")

        XCTAssertEqual(try activeCount(pool: pool), 1)
    }

    // MARK: - Prevention of future duplicates

    func test_uniqueIndex_blocksRecordingTheSameReadingAgain() throws {
        let pool = try makePool()  // all migrations, index already present
        let s = Int64(1_700_000_000)
        try seedReading(pool: pool, uuid: "u-first", startAt: s, value: 82.8, origin: "xiaomiSports", ingestedAt: 100)

        // A plain INSERT of the same reading (new UUID) must now violate the unique index.
        XCTAssertThrowsError(try seedReading(
            pool: pool, uuid: "u-second", startAt: s, value: 82.8, origin: "xiaomiMijia", ingestedAt: 200
        ), "a second active row with the same reading must be rejected")

        XCTAssertEqual(try activeCount(pool: pool), 1)
    }

    func test_insertOrIgnore_skipsDuplicate_sameAsSyncPath() throws {
        let pool = try makePool()
        let s = Int64(1_700_000_000)
        try seedReading(pool: pool, uuid: "u-first", startAt: s, value: 82.8, origin: "xiaomiSports", ingestedAt: 100)

        // The sync coordinators use `INSERT OR IGNORE` on the primary key — which also ignores
        // the new partial unique-index conflict — so a re-fetched duplicate is silently skipped.
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO health_samples_raw
                  (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                   source_name, source_bundle_id, ingested_at, is_deleted, source_origin)
                VALUES (?, ?, 'quantity', ?, 'kg', ?, ?, NULL, NULL, ?, 0, ?)
                """, arguments: ["u-second", Self.bodyMass, 82.8, s, s, 200, "xiaomiMijia"])
        }

        XCTAssertEqual(try activeCount(pool: pool), 1, "INSERT OR IGNORE must not add the duplicate active row")
    }
}
