import XCTest
import GRDB
@testable import BridgeCore

final class BridgePublishSchedulingTests: XCTestCase {
    private var root: URL!
    private var pool: DatabasePool!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pool = try DatabasePool(path: root.appendingPathComponent("source.sqlite").path)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE bridge_outbox (
                    sequence INTEGER PRIMARY KEY,
                    manifest BLOB NOT NULL,
                    payload BLOB NOT NULL,
                    acknowledged_at REAL
                )
                """)
        }
    }

    override func tearDownWithError() throws {
        pool = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testLargeAcknowledgedLedgerReadsPayloadOnlyForSevenPendingBatches() throws {
        for sequence in 1...418 {
            try insert(sequence: Int64(sequence), acknowledgedAt: sequence <= 411 ? 100 : nil)
        }

        var payloadReads: [Int64] = []
        var maintenanceVisits: [Int64] = []
        let syncRoot = root.appendingPathComponent("sync", isDirectory: true)
        let result = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 16,
            maxMaintenanceBatches: 11,
            now: Date(),
            onPayloadRead: { payloadReads.append($0) },
            onMaintenanceVisit: { maintenanceVisits.append($0) }
        )

        XCTAssertEqual(payloadReads, Array(412...418).map(Int64.init))
        XCTAssertEqual(maintenanceVisits, Array(1...11).map(Int64.init))
        XCTAssertTrue(result.status.contains("7 批"))
        XCTAssertEqual(result.publishedBatchCount, 7)
        XCTAssertFalse(result.shouldContinueImmediately)

        for sequence in 412...418 {
            let expected = try row(sequence: Int64(sequence))
            let manifest = try JSONDecoder().decode(BridgeManifest.self, from: expected.manifest)
            let directory = syncRoot.appendingPathComponent("batches/\(BridgeWire.folder(manifest))")
            let writtenPayload = try Data(contentsOf: directory.appendingPathComponent("records.jsonl"))
            let writtenManifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            XCTAssertEqual(writtenPayload, expected.payload)
            XCTAssertEqual(writtenManifest, expected.manifest)
            XCTAssertEqual(manifest.bytes, expected.payload.count)
            XCTAssertEqual(manifest.sha256, BridgeWire.hash(expected.payload))
        }

        payloadReads.removeAll()
        maintenanceVisits.removeAll()
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 16,
            maxMaintenanceBatches: 11,
            now: Date(),
            onPayloadRead: { payloadReads.append($0) },
            onMaintenanceVisit: { maintenanceVisits.append($0) }
        )
        XCTAssertTrue(payloadReads.isEmpty, "Freshly published batches must not be rewritten on every pass")
        XCTAssertEqual(maintenanceVisits, Array(12...22).map(Int64.init), "The durable cursor must advance instead of rescanning the first page")
    }

    func testValidReceiptAcknowledgesWithoutPayloadReadAndInvalidReceiptDoesNot() throws {
        try insert(sequence: 1, acknowledgedAt: nil)
        try insert(sequence: 2, acknowledgedAt: nil)
        let syncRoot = root.appendingPathComponent("sync", isDirectory: true)
        let receipts = syncRoot.appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)

        let first = try row(sequence: 1)
        let firstManifest = try JSONDecoder().decode(BridgeManifest.self, from: first.manifest)
        try BridgeWire.encode(receipt(for: firstManifest))
            .write(to: receipts.appendingPathComponent(BridgeWire.folder(firstManifest) + ".json"), options: .atomic)

        let second = try row(sequence: 2)
        let secondManifest = try JSONDecoder().decode(BridgeManifest.self, from: second.manifest)
        let invalid = BridgeReceipt(
            dataset: secondManifest.dataset,
            epoch: secondManifest.epoch,
            sequence: secondManifest.sequence,
            sha256: "not-the-payload-hash",
            receivedAt: 200
        )
        try BridgeWire.encode(invalid)
            .write(to: receipts.appendingPathComponent(BridgeWire.folder(secondManifest) + ".json"), options: .atomic)

        var payloadReads: [Int64] = []
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 8,
            maxMaintenanceBatches: 8,
            now: Date(timeIntervalSince1970: 500),
            onPayloadRead: { payloadReads.append($0) }
        )

        XCTAssertEqual(payloadReads, [2])
        let acknowledgements = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT sequence,acknowledged_at FROM bridge_outbox ORDER BY sequence")
        }
        XCTAssertEqual(acknowledgements[0]["acknowledged_at"] as Double?, 500)
        XCTAssertNil(acknowledgements[1]["acknowledged_at"] as Double?)
    }

    func testInterruptedPublicationReplaysExactDurableBytes() throws {
        try insert(sequence: 1, acknowledgedAt: nil)
        let syncRoot = root.appendingPathComponent("sync", isDirectory: true)
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 8,
            maxMaintenanceBatches: 8,
            now: Date()
        )

        let expected = try row(sequence: 1)
        let manifest = try JSONDecoder().decode(BridgeManifest.self, from: expected.manifest)
        let directory = syncRoot.appendingPathComponent("batches/\(BridgeWire.folder(manifest))")
        let payloadURL = directory.appendingPathComponent("records.jsonl")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        try Data("interrupted-write".utf8).write(to: payloadURL, options: .atomic)

        var payloadReads: [Int64] = []
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 8,
            maxMaintenanceBatches: 8,
            now: Date(),
            onPayloadRead: { payloadReads.append($0) }
        )

        XCTAssertEqual(payloadReads, [1])
        XCTAssertEqual(try Data(contentsOf: payloadURL), expected.payload)
        XCTAssertEqual(try Data(contentsOf: manifestURL), expected.manifest)
        XCTAssertEqual(BridgeWire.hash(try Data(contentsOf: payloadURL)), manifest.sha256)
    }

    func testReceiptMaintenanceIsBoundedFairAndKeepsUnvalidatedOrRecentPayloads() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for sequence in 1...6 {
            let age = sequence == 5 ? 6.0 * 86_400 : 8.0 * 86_400
            try insert(sequence: Int64(sequence), acknowledgedAt: now.timeIntervalSince1970 - age)
            try writePublishedBatchAndReceipt(sequence: Int64(sequence), syncRoot: root.appendingPathComponent("sync"))
        }
        try corruptReceipt(sequence: 6, syncRoot: root.appendingPathComponent("sync"))

        var firstVisits: [Int64] = []
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: root.appendingPathComponent("sync"),
            maxPublishBatches: 2,
            maxMaintenanceBatches: 2,
            now: now,
            onMaintenanceVisit: { firstVisits.append($0) }
        )
        XCTAssertEqual(firstVisits, [1, 2])
        XCTAssertEqual(try payloadSize(sequence: 1), 0)
        XCTAssertEqual(try payloadSize(sequence: 2), 0)
        XCTAssertGreaterThan(try payloadSize(sequence: 3), 0)

        var secondVisits: [Int64] = []
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: root.appendingPathComponent("sync"),
            maxPublishBatches: 2,
            maxMaintenanceBatches: 2,
            now: now,
            onMaintenanceVisit: { secondVisits.append($0) }
        )
        XCTAssertEqual(secondVisits, [3, 4])

        var thirdVisits: [Int64] = []
        _ = try BridgeSource.publishPass(
            pool: pool,
            root: root.appendingPathComponent("sync"),
            maxPublishBatches: 2,
            maxMaintenanceBatches: 2,
            now: now,
            onMaintenanceVisit: { thirdVisits.append($0) }
        )
        XCTAssertEqual(thirdVisits, [5, 6])
        XCTAssertGreaterThan(try payloadSize(sequence: 5), 0, "Payload must remain during the seven-day retention window")
        XCTAssertGreaterThan(try payloadSize(sequence: 6), 0, "An invalid receipt must never authorize payload deletion")
    }

    func testLargePendingSnapshotRequestsOnlyBoundedForwardProgressPasses() throws {
        for sequence in 1...65 {
            try insert(sequence: Int64(sequence), acknowledgedAt: nil)
        }
        let syncRoot = root.appendingPathComponent("sync", isDirectory: true)

        let first = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 32,
            maxMaintenanceBatches: 4,
            now: Date()
        )
        XCTAssertEqual(first.publishedBatchCount, 32)
        XCTAssertTrue(first.shouldContinueImmediately)

        let second = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 32,
            maxMaintenanceBatches: 4,
            now: Date()
        )
        XCTAssertEqual(second.publishedBatchCount, 32)
        XCTAssertTrue(second.shouldContinueImmediately)

        let third = try BridgeSource.publishPass(
            pool: pool,
            root: syncRoot,
            maxPublishBatches: 32,
            maxMaintenanceBatches: 4,
            now: Date()
        )
        XCTAssertEqual(third.publishedBatchCount, 1)
        XCTAssertFalse(third.shouldContinueImmediately)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: syncRoot.appendingPathComponent("batches").path).count,
            65
        )
    }

    private func insert(sequence: Int64, acknowledgedAt: Double?) throws {
        let payload = Data("{\"sequence\":\(sequence),\"stable\":true}\n".utf8)
        let manifest = BridgeManifest(
            dataset: "11111111-1111-1111-1111-111111111111",
            epoch: "22222222-2222-2222-2222-222222222222",
            epochStarted: 10,
            sequence: sequence,
            snapshot: false,
            finalSnapshot: false,
            historyStart: 0,
            timeZone: "Asia/Shanghai",
            generatedAt: 20,
            count: 1,
            bytes: payload.count,
            sha256: BridgeWire.hash(payload)
        )
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO bridge_outbox(sequence,manifest,payload,acknowledged_at) VALUES(?,?,?,?)",
                arguments: [sequence, try BridgeWire.encode(manifest), payload, acknowledgedAt]
            )
        }
    }

    private func row(sequence: Int64) throws -> (manifest: Data, payload: Data) {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT manifest,payload FROM bridge_outbox WHERE sequence=?", arguments: [sequence])!
            return (row["manifest"], row["payload"])
        }
    }

    private func payloadSize(sequence: Int64) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT length(payload) FROM bridge_outbox WHERE sequence=?", arguments: [sequence])!
        }
    }

    private func receipt(for manifest: BridgeManifest) -> BridgeReceipt {
        BridgeReceipt(
            dataset: manifest.dataset,
            epoch: manifest.epoch,
            sequence: manifest.sequence,
            sha256: manifest.sha256,
            receivedAt: 200
        )
    }

    private func writePublishedBatchAndReceipt(sequence: Int64, syncRoot: URL) throws {
        let stored = try row(sequence: sequence)
        let manifest = try JSONDecoder().decode(BridgeManifest.self, from: stored.manifest)
        let directory = syncRoot.appendingPathComponent("batches/\(BridgeWire.folder(manifest))", isDirectory: true)
        let receipts = syncRoot.appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try stored.payload.write(to: directory.appendingPathComponent("records.jsonl"), options: .atomic)
        try stored.manifest.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try BridgeWire.encode(receipt(for: manifest))
            .write(to: receipts.appendingPathComponent(BridgeWire.folder(manifest) + ".json"), options: .atomic)
    }

    private func corruptReceipt(sequence: Int64, syncRoot: URL) throws {
        let stored = try row(sequence: sequence)
        let manifest = try JSONDecoder().decode(BridgeManifest.self, from: stored.manifest)
        let bad = BridgeReceipt(
            dataset: manifest.dataset,
            epoch: manifest.epoch,
            sequence: manifest.sequence,
            sha256: "corrupted",
            receivedAt: 200
        )
        try BridgeWire.encode(bad).write(
            to: syncRoot.appendingPathComponent("receipts/\(BridgeWire.folder(manifest)).json"),
            options: .atomic
        )
    }
}
