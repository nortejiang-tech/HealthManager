import XCTest
import GRDB
@testable import HealthManager

final class SyncRestoreIntegrationTests: XCTestCase {
    private let type = "HKQuantityTypeIdentifierBodyMass"

    func test_restoreBarrierDrainsWriterBeforeRestoredValueIsImported() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(
            store: store,
            projectionWorker: ProjectionWorker(database: database)
        )
        let latch = RestoreWriterLatch()
        let demand = SyncDemand(types: [type], reason: .observer, intentID: UUID())
        let writer = Task {
            try? await runner.submit(demand) {
                let claim = try XCTUnwrap(store.claim(type: self.type, token: UUID()))
                await latch.markStarted()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    // Simulate a query callback already queued when cancellation won. The
                    // barrier must wait until this final page transaction completes.
                }
                _ = try store.commitPage(.init(
                    claim: claim,
                    addedRows: [self.sample(value: 99)],
                    deletedUUIDs: [],
                    newAnchorData: Data([1]),
                    drained: true,
                    calendar: .current,
                    projectionVersion: 1
                ))
                return SyncRunnerSliceResult()
            }
        }
        await latch.waitUntilStarted()

        try await runner.beginRestore()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO body_metrics_daily(date, weight_kg, computed_at)
                VALUES (?, 68, 123)
                ON CONFLICT(date) DO UPDATE SET weight_kg=68, computed_at=123
                """, arguments: [todayKey()])
        }
        _ = await writer.result

        let isRunning = await runner.isRunning
        XCTAssertEqual(try bodyWeight(database), 68)
        XCTAssertTrue(try store.runtimeState().restoreInProgress)
        XCTAssertFalse(isRunning)
    }

    func test_restoreMarkerAndPendingDemandSurviveDatabaseReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        let firstPool = try DatabasePool(path: url.path)
        try Migrations.run(on: firstPool)
        let firstStore = SyncWorkStore(pool: firstPool)
        try firstStore.request(types: [type], reason: .observer)
        let runner = SyncRunner(store: firstStore)
        try await runner.beginRestore()

        let secondPool = try DatabasePool(path: url.path)
        try Migrations.run(on: secondPool)
        let reopened = SyncWorkStore(pool: secondPool)
        XCTAssertTrue(try reopened.runtimeState().restoreInProgress)
        XCTAssertTrue(try XCTUnwrap(reopened.work(for: type)).isPending)
        XCTAssertTrue(try reopened.pendingWork().isEmpty)
    }

    func test_successClearsPauseWithoutDeletingPendingDemand() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .observer)
        let runner = SyncRunner(store: store)

        try await runner.beginRestore()
        try await runner.finishRestore(success: true)

        XCTAssertFalse(try store.runtimeState().restoreInProgress)
        XCTAssertTrue(try XCTUnwrap(store.work(for: type)).isPending)
        XCTAssertNotNil(try store.claim(type: type, token: UUID()))
    }

    func test_failedRestoreKeepsPauseAndRestoredAggregateWithoutRawEvidence() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(store: store)
        try await runner.beginRestore()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO body_metrics_daily(date, weight_kg, computed_at)
                VALUES ('2020-01-01', 66, 42)
                """)
        }
        try await runner.finishRestore(success: false)

        XCTAssertTrue(try store.runtimeState().restoreInProgress)
        let values = try database.read { db in
            (
                try Double.fetchOne(db, sql: "SELECT weight_kg FROM body_metrics_daily WHERE date='2020-01-01'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw")
            )
        }
        XCTAssertEqual(values.0, 66)
        XCTAssertEqual(values.1, 0)
    }

    private func sample(value: Double) -> HealthSampleRaw {
        let start = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) + 3_600
        return HealthSampleRaw(
            sampleUUID: "late-page",
            hkType: type,
            kind: .quantity,
            value: value,
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

    private func todayKey() -> String {
        DashboardLoader.dateKey.string(from: Calendar.current.startOfDay(for: Date()))
    }

    private func bodyWeight(_ database: DatabaseManager) throws -> Double? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT weight_kg FROM body_metrics_daily WHERE date = ?",
                arguments: [todayKey()]
            )
        }
    }
}

private actor RestoreWriterLatch {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
