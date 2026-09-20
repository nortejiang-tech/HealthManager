import XCTest
import GRDB
@testable import HealthManager

final class SyncPageRunnerTests: XCTestCase {
    private let type = "HKQuantityTypeIdentifierBodyMass"

    func test_pages2501AddedRowsIn1000ChunksAndRequiresEmptyDrainPage() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .foreground)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let rows = (0..<2_501).map(makeSample)
        let calls = Counter()

        let result = try await makeRunner(store).run(
            claim: claim,
            initialAnchorData: nil,
            budget: generousBudget(pages: 8)
        ) { anchor, limit in
            XCTAssertEqual(limit, 1_000)
            calls.value += 1
            let offset = self.decodeOffset(anchor)
            let end = min(offset + limit, rows.count)
            let page = offset < end ? Array(rows[offset..<end]) : []
            return SyncFetchedPage(
                addedRows: page,
                deletedUUIDs: [],
                newAnchorData: self.encodeOffset(end)
            )
        }

        XCTAssertEqual(result.state, .drained)
        XCTAssertEqual(result.pagesCommitted, 4)
        XCTAssertEqual(result.actualInserted, 2_501)
        XCTAssertEqual(calls.value, 4)
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 1)
        XCTAssertEqual(try rawCount(database), 2_501)
    }

    func test_deletionOnlyPagesPersistAndContinueUntilEmptyPage() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            for index in 0..<1_001 { try self.makeSample(index).insert(db) }
        }
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .observer)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let uuids = (0..<1_001).map { "sample-\($0)" }

        let result = try await makeRunner(store).run(
            claim: claim,
            initialAnchorData: nil,
            budget: generousBudget(pages: 8)
        ) { anchor, limit in
            let offset = self.decodeOffset(anchor)
            let end = min(offset + limit, uuids.count)
            let page = offset < end ? Array(uuids[offset..<end]) : []
            return SyncFetchedPage(
                addedRows: [],
                deletedUUIDs: page,
                newAnchorData: self.encodeOffset(end)
            )
        }

        XCTAssertEqual(result.state, .drained)
        XCTAssertEqual(result.pagesCommitted, 3)
        XCTAssertEqual(result.actualDeleted, 1_001)
        XCTAssertEqual(try deletedCount(database), 1_001)
    }

    func test_pageBudgetYieldsAndNextSliceResumesAtCommittedAnchor() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let rows = (0..<1_500).map(makeSample)
        try store.request(types: [type], reason: .background)
        let firstClaim = try XCTUnwrap(store.claim(type: type, token: UUID()))

        let first = try await makeRunner(store).run(
            claim: firstClaim,
            initialAnchorData: nil,
            budget: generousBudget(pages: 1),
            fetchPage: pageSource(rows)
        )
        XCTAssertEqual(first.state, .hasPending)
        XCTAssertEqual(first.actualInserted, 1_000)
        XCTAssertTrue(try XCTUnwrap(store.work(for: type)).isPending)
        let saved = try anchorData(database)
        XCTAssertEqual(decodeOffset(saved), 1_000)

        let secondClaim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let second = try await makeRunner(store).run(
            claim: secondClaim,
            initialAnchorData: saved,
            budget: generousBudget(pages: 3),
            fetchPage: pageSource(rows)
        )
        XCTAssertEqual(second.state, .drained)
        XCTAssertEqual(second.actualInserted, 500)
        XCTAssertFalse(try XCTUnwrap(store.work(for: type)).isPending)
    }

    func test_secondPageFailureKeepsFirstPageAnchorAndPendingGeneration() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .observer)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let firstRows = (0..<1_000).map(makeSample)

        do {
            _ = try await makeRunner(store).run(
                claim: claim,
                initialAnchorData: nil,
                budget: generousBudget(pages: 4)
            ) { anchor, _ in
                if self.decodeOffset(anchor) == 1_000 { throw FixtureError.query }
                return SyncFetchedPage(
                    addedRows: firstRows,
                    deletedUUIDs: [],
                    newAnchorData: self.encodeOffset(1_000)
                )
            }
            XCTFail("Expected second page failure")
        } catch FixtureError.query {}

        XCTAssertEqual(try rawCount(database), 1_000)
        XCTAssertEqual(decodeOffset(try anchorData(database)), 1_000)
        XCTAssertTrue(try XCTUnwrap(store.work(for: type)).isPending)
    }

    func test_mappingFailureBeforeCommitPreservesOldAnchorAndRows() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .observer)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))

        do {
            _ = try await makeRunner(store).run(
                claim: claim,
                initialAnchorData: nil,
                budget: generousBudget(pages: 2)
            ) { _, _ in
                throw SyncPageRunnerError.mappingFailed(type: self.type, sampleID: "unsupported")
            }
            XCTFail("Expected mapping failure")
        } catch SyncPageRunnerError.mappingFailed(let type, let sampleID) {
            XCTAssertEqual(type, self.type)
            XCTAssertEqual(sampleID, "unsupported")
        }

        XCTAssertEqual(try rawCount(database), 0)
        XCTAssertNil(try anchorData(database))
        XCTAssertTrue(try XCTUnwrap(store.work(for: type)).isPending)
    }

    func test_duplicateDataPagesUseActualInsertCountAndStillDrain() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .foreground)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        let row = makeSample(1)

        let result = try await makeRunner(store).run(
            claim: claim,
            initialAnchorData: nil,
            budget: generousBudget(pages: 4)
        ) { anchor, _ in
            switch self.decodeOffset(anchor) {
            case 0:
                return SyncFetchedPage(addedRows: [row], deletedUUIDs: [], newAnchorData: self.encodeOffset(1))
            case 1:
                return SyncFetchedPage(addedRows: [row], deletedUUIDs: [], newAnchorData: self.encodeOffset(2))
            default:
                return SyncFetchedPage(addedRows: [], deletedUUIDs: [], newAnchorData: self.encodeOffset(2))
            }
        }

        XCTAssertEqual(result.pagesCommitted, 3)
        XCTAssertEqual(result.actualInserted, 1)
        XCTAssertEqual(try rawCount(database), 1)
    }

    func test_emptyDrainPageDoesNotCreateDirtyProjection() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        try store.request(types: [type], reason: .foreground)
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))

        let result = try await makeRunner(store).run(
            claim: claim,
            initialAnchorData: nil,
            budget: generousBudget(pages: 1)
        ) { _, _ in
            SyncFetchedPage(addedRows: [], deletedUUIDs: [], newAnchorData: self.encodeOffset(0))
        }

        XCTAssertEqual(result.state, .drained)
        XCTAssertTrue(try store.projectionWork().isEmpty)
    }

    func test_corruptAnchorRequiresRepairWithoutDeletingEvidence() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let corrupt = Data([0x00, 0x01, 0x02])
        try database.write { db in
            try SyncAnchor(hkType: type, anchorData: corrupt, updatedAt: 1).insert(db)
        }

        XCTAssertThrowsError(try IncrementalSyncCoordinator.decodeAnchor(corrupt, type: type)) { error in
            XCTAssertEqual(error as? SyncPageRunnerError, .repairRequired(type: self.type))
        }
        XCTAssertEqual(try anchorData(database), corrupt)
    }

    private func makeRunner(_ store: SyncWorkStore) -> SyncPageRunner {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return SyncPageRunner(workStore: store, calendar: calendar)
    }

    private func generousBudget(pages: Int) -> SyncPageBudget {
        SyncPageBudget(maximumPages: pages, deadline: Date().addingTimeInterval(60))
    }

    private func pageSource(
        _ rows: [HealthSampleRaw]
    ) -> (Data?, Int) async throws -> SyncFetchedPage {
        { anchor, limit in
            let offset = self.decodeOffset(anchor)
            let end = min(offset + limit, rows.count)
            let page = offset < end ? Array(rows[offset..<end]) : []
            return SyncFetchedPage(
                addedRows: page,
                deletedUUIDs: [],
                newAnchorData: self.encodeOffset(end)
            )
        }
    }

    private func encodeOffset(_ value: Int) -> Data {
        Data(String(value).utf8)
    }

    private func decodeOffset(_ data: Data?) -> Int {
        guard let data, let text = String(data: data, encoding: .utf8) else { return 0 }
        return Int(text) ?? 0
    }

    private func anchorData(_ database: DatabaseManager) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT anchor_data FROM sync_anchors WHERE hk_type = ?",
                arguments: [type]
            )
        }
    }

    private func rawCount(_ database: DatabaseManager) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw") ?? -1
        }
    }

    private func deletedCount(_ database: DatabaseManager) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 1") ?? -1
        }
    }

    private func makeSample(_ index: Int) -> HealthSampleRaw {
        let start = Int64(1_795_000_000 + index)
        return HealthSampleRaw(
            sampleUUID: "sample-\(index)",
            hkType: type,
            kind: .quantity,
            value: Double(index),
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

private final class Counter: @unchecked Sendable {
    var value = 0
}

private enum FixtureError: Error {
    case query
}
