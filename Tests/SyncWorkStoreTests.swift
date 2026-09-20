import XCTest
import GRDB
@testable import HealthManager

final class SyncWorkStoreTests: XCTestCase {
    private let type = "HKQuantityTypeIdentifierBodyMass"

    func test_v14SchemaCreatesRuntimeControlTablesWithoutChangingBackupContent() throws {
        let pool = try makePool()
        let tables = try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }

        XCTAssertTrue(tables.contains("sync_type_work"))
        XCTAssertTrue(tables.contains("sync_projection_work"))
        XCTAssertTrue(tables.contains("sync_runtime_state"))
        XCTAssertEqual(try SyncWorkStore(pool: pool).runtimeState().restoreInProgress, false)
    }

    func test_pendingAndDirtyWorkSurviveASecondDatabasePool() throws {
        let url = temporaryDatabaseURL()
        let firstPool = try DatabasePool(path: url.path)
        try Migrations.run(on: firstPool)
        let first = SyncWorkStore(pool: firstPool)
        try first.request(types: [type], reason: .observer)
        let claim = try XCTUnwrap(first.claim(type: type, token: UUID()))
        let calendar = shanghaiCalendar()
        let sample = makeSample(uuid: "persisted", date: makeDate(calendar: calendar))

        _ = try first.commitPage(.init(
            claim: claim,
            addedRows: [sample],
            deletedUUIDs: [],
            newAnchorData: Data([1, 2, 3]),
            drained: false,
            calendar: calendar,
            projectionVersion: 1
        ))

        let secondPool = try DatabasePool(path: url.path)
        try Migrations.run(on: secondPool)
        let reopened = SyncWorkStore(pool: secondPool)

        XCTAssertEqual(try reopened.work(for: type)?.requestedGeneration, 1)
        XCTAssertEqual(try reopened.work(for: type)?.completedGeneration, 0)
        XCTAssertEqual(try reopened.projectionWork().count, 1)
        XCTAssertEqual(try reopened.projectionWork().first?.key.localDate, "2026-09-20")
    }

    func test_commitPageUsesActualInsertDeleteCountsAndUnknownTombstoneHasNoFakeDate() throws {
        let pool = try makePool()
        let store = SyncWorkStore(pool: pool)
        let calendar = shanghaiCalendar()
        let date = makeDate(calendar: calendar)
        let row = makeSample(uuid: "known", date: date)

        try store.request(types: [type], reason: .observer)
        let firstClaim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let inserted = try store.commitPage(.init(
            claim: firstClaim,
            addedRows: [row, row],
            deletedUUIDs: [],
            newAnchorData: Data([4]),
            drained: true,
            calendar: calendar,
            projectionVersion: 1
        ))
        XCTAssertEqual(inserted.actualInserted, 1)
        XCTAssertEqual(inserted.changedProjectionKeys.map(\.localDate), ["2026-09-20"])

        try store.request(types: [type], reason: .observer)
        let secondClaim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let deleted = try store.commitPage(.init(
            claim: secondClaim,
            addedRows: [row],
            deletedUUIDs: ["known", "unknown"],
            newAnchorData: Data([5]),
            drained: true,
            calendar: calendar,
            projectionVersion: 1
        ))

        XCTAssertEqual(deleted.actualInserted, 0)
        XCTAssertEqual(deleted.actualDeleted, 1)
        XCTAssertEqual(deleted.unknownTombstones, 1)
        XCTAssertEqual(deleted.changedProjectionKeys.map(\.localDate), ["2026-09-20"])
        let projection = try XCTUnwrap(store.projectionWork().first)
        XCTAssertEqual(projection.generation, 2)
    }

    func test_newGenerationIsNotClearedByOlderDrainedClaim() throws {
        let pool = try makePool()
        let store = SyncWorkStore(pool: pool)
        try store.request(types: [type], reason: .observer)
        let firstClaim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        try store.request(types: [type], reason: .foreground)

        _ = try store.commitPage(.init(
            claim: firstClaim,
            addedRows: [],
            deletedUUIDs: [],
            newAnchorData: Data([1]),
            drained: true,
            calendar: shanghaiCalendar(),
            projectionVersion: 1
        ))

        let work = try XCTUnwrap(store.work(for: type))
        XCTAssertEqual(work.requestedGeneration, 2)
        XCTAssertEqual(work.completedGeneration, 1)
        XCTAssertTrue(work.isPending)
        XCTAssertNotEqual(work.reasonMask, 0)
    }

    func test_eachFailurePointRollsBackRowsDeletionAnchorDirtyAndCompletion() throws {
        let points: [SyncWorkStoreFailurePoint] = [
            .afterInsert,
            .afterDelete,
            .beforeAnchor,
            .afterAnchorBeforeCommit
        ]

        for point in points {
            let pool = try makePool()
            let store = SyncWorkStore(pool: pool)
            let calendar = shanghaiCalendar()
            let existing = makeSample(uuid: "to-delete", date: makeDate(calendar: calendar))
            try pool.write { db in try existing.insert(db) }
            try store.request(types: [type], reason: .observer)
            let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))

            XCTAssertThrowsError(try store.commitPage(.init(
                claim: claim,
                addedRows: [makeSample(uuid: "to-insert", date: makeDate(calendar: calendar))],
                deletedUUIDs: ["to-delete"],
                newAnchorData: Data([9]),
                drained: true,
                calendar: calendar,
                projectionVersion: 1
            ), injecting: point)) { error in
                XCTAssertEqual(error as? SyncWorkStoreError, .injected(point))
            }

            let insertedCount = try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE sample_uuid = 'to-insert'") ?? -1
            }
            let existingDeleted: Bool = try pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT is_deleted FROM health_samples_raw WHERE sample_uuid = 'to-delete'") ?? true
            }
            let anchorCount = try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_anchors") ?? -1
            }
            XCTAssertEqual(insertedCount, 0, "failure point \(point)")
            XCTAssertFalse(existingDeleted, "failure point \(point)")
            XCTAssertEqual(anchorCount, 0, "failure point \(point)")
            XCTAssertTrue(try store.projectionWork().isEmpty, "failure point \(point)")
            XCTAssertEqual(try store.work(for: type)?.completedGeneration, 0)
        }
    }

    func test_deferredAndRestoreMarkersPersistWithoutDeletingPendingWork() throws {
        let url = temporaryDatabaseURL()
        let firstPool = try DatabasePool(path: url.path)
        try Migrations.run(on: firstPool)
        let first = SyncWorkStore(pool: firstPool)
        try first.request(types: [type], reason: .background)
        let claim = try XCTUnwrap(first.claim(type: type, token: UUID()))
        try first.deferClaim(claim, reason: .waitForUnlock, errorCode: "locked")
        try first.setRestoreInProgress(true, pausedReason: "backup_restore")

        _ = try SyncJobRecovery(database: DatabaseManager.makeInMemoryForTesting())
            .recoverInterruptedWork()

        let secondPool = try DatabasePool(path: url.path)
        try Migrations.run(on: secondPool)
        let reopened = SyncWorkStore(pool: secondPool)
        XCTAssertEqual(try reopened.work(for: type)?.deferredReason, .waitForUnlock)
        XCTAssertEqual(try reopened.work(for: type)?.requestedGeneration, 1)
        XCTAssertTrue(try reopened.runtimeState().restoreInProgress)
        XCTAssertEqual(try reopened.runtimeState().runnerPausedReason, "backup_restore")
        XCTAssertTrue(try reopened.pendingWork().isEmpty)
    }

    func test_runtimeControlDoesNotOverwriteRestoredDailyAggregatesWithoutRawEvidence() throws {
        let pool = try makePool()
        let store = SyncWorkStore(pool: pool)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO body_metrics_daily (date, weight_kg, computed_at)
                VALUES ('2026-09-20', 72.5, 1)
                """)
        }

        try store.setRestoreInProgress(true, pausedReason: "backup_restore")
        try store.request(types: [type], reason: .foreground)
        try store.setRestoreInProgress(false)

        let weight = try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT weight_kg FROM body_metrics_daily WHERE date = '2026-09-20'")
        }
        XCTAssertEqual(weight, 72.5)
    }

    private func makePool() throws -> DatabasePool {
        let pool = try DatabasePool(path: temporaryDatabaseURL().path)
        try Migrations.run(on: pool)
        return pool
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-sync-work-\(UUID().uuidString).sqlite")
    }

    private func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func makeDate(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: 20,
            hour: 8
        ))!
    }

    private func makeSample(uuid: String, date: Date) -> HealthSampleRaw {
        let start = Int64(date.timeIntervalSince1970)
        return HealthSampleRaw(
            sampleUUID: uuid,
            hkType: type,
            kind: .quantity,
            value: 72.5,
            unit: "kg",
            startAt: start,
            endAt: start + 1,
            sourceName: "fixture",
            sourceBundleId: "fixture.bundle",
            deviceName: nil,
            deviceModel: nil,
            ingestedAt: start + 2,
            isDeleted: false,
            extraJson: nil,
            sourceOrigin: "unknown"
        )
    }
}
