import Foundation
import GRDB

public struct BridgePublishResult: Sendable {
    public let status: String
    public let publishedBatchCount: Int
    public let acknowledgedBatchCount: Int
    public let shouldContinueImmediately: Bool
}

public enum BridgeSource {
    private struct PublishCursor: Codable {
        var pendingAfter: Int64 = 0
        var maintenanceAfter: Int64 = 0
    }

    private struct OutboxMetadata {
        let sequence: Int64
        let manifestData: Data
        let manifest: BridgeManifest
        let acknowledgedAt: Double?
    }

    private static let cursorFileName = ".healthbridge-source-cursor.json"
    private static let defaultBatchBudget = 32
    private static let replayInterval: TimeInterval = 15 * 60

    public static func migrate(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE bridge_state (id INTEGER PRIMARY KEY CHECK(id=1), dataset TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0,
          epoch TEXT, epoch_started REAL, history_start REAL, timezone TEXT, cursor INTEGER NOT NULL DEFAULT 0, sequence INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE bridge_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL, record_key TEXT NOT NULL);
        CREATE TABLE bridge_outbox (sequence INTEGER PRIMARY KEY, manifest BLOB NOT NULL, payload BLOB NOT NULL, acknowledged_at REAL);
        """)
        try db.execute(sql: "INSERT INTO bridge_state(id,dataset) VALUES(1,?)", arguments: [UUID().uuidString])
        for spec in BridgeWire.tables {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let ref = action == "DELETE" ? "OLD" : "NEW"
                try db.execute(sql: """
                CREATE TRIGGER bridge_\(spec.name)_\(action.lowercased()) AFTER \(action) ON \(spec.name)
                WHEN (SELECT enabled FROM bridge_state WHERE id=1)=1 BEGIN
                  INSERT INTO bridge_changes(entity,record_key) VALUES('\(spec.name)',CAST(\(ref).\(spec.key) AS TEXT));
                END;
                """)
            }
        }
    }
    public static func setEnabled(_ enabled: Bool, db: Database) throws {
        let was = try Bool.fetchOne(db, sql: "SELECT enabled FROM bridge_state WHERE id=1") ?? false
        try db.execute(sql: "UPDATE bridge_state SET enabled=? WHERE id=1", arguments: [enabled])
        if enabled && !was { try reset(db) }
    }
    public static func reset(_ db: Database) throws {
        try db.execute(sql: "UPDATE bridge_state SET epoch=NULL,cursor=0,sequence=0 WHERE id=1; DELETE FROM bridge_outbox; DELETE FROM bridge_changes;")
        if try db.columns(in: "bridge_state").contains(where: { $0.name == "paused_reason" }) {
            try db.execute(sql: "UPDATE bridge_state SET paused_reason=NULL WHERE id=1")
        }
    }
    public static func enabled(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT enabled FROM bridge_state WHERE id=1") ?? false
    }
    private static func record(_ db: Database, table: String, key: String, since: Double, zone: String) throws -> BridgeRecord {
        guard let spec = BridgeWire.tables.first(where: { $0.name == table }) else { throw BridgeError.invalid("Unknown source table") }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(spec.key)=?", arguments: [key]) else {
            return BridgeRecord(table: table, key: key, json: nil)
        }
        return try normalized(row, table: table, key: key, since: since, zone: zone)
    }
    private static func normalized(_ row: Row, table: String, key: String, since: Double, zone: String) throws -> BridgeRecord {
        var object = BridgeWire.object(row)
        object.removeValue(forKey: "bridge_key")
        if table == "health_samples_raw" {
            let type: String = row["hk_type"]; let start: Double = row["start_at"]; let deleted: Bool = row["is_deleted"]
            if !BridgeWire.types.contains(type) || start < since || deleted { return BridgeRecord(table: table, key: key, json: nil) }
        } else if BridgeWire.tables.first(where: { $0.name == table })?.key == "date" {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: zone)
            if key < formatter.string(from: Date(timeIntervalSince1970: since)) { return BridgeRecord(table: table, key: key, json: nil) }
        }
        return BridgeRecord(table: table, key: key, json: try BridgeWire.json(object))
    }
    /// Call within one writer transaction: snapshot, watermark and durable outbox commit together.
    public static func prepare(_ db: Database, historyStart: Date, now: Date = Date(), timeZone: String = TimeZone.current.identifier) throws {
        guard try enabled(db), let state = try Row.fetchOne(db, sql: "SELECT * FROM bridge_state WHERE id=1") else { return }
        if state.hasColumn("paused_reason"), let reason: String = state["paused_reason"] { throw BridgeError.invalid(reason) }
        let dataset: String = state["dataset"]
        let oldEpoch: String? = state["epoch"]
        let epoch = oldEpoch ?? UUID().uuidString
        let started: Double = oldEpoch == nil ? now.timeIntervalSince1970 : state["epoch_started"]
        let since: Double = oldEpoch == nil ? historyStart.timeIntervalSince1970 : state["history_start"]
        let zone: String = oldEpoch == nil ? timeZone : state["timezone"]
        var seq: Int64 = state["sequence"]
        var cursor: Int64 = state["cursor"]
        if oldEpoch == nil {
            cursor = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq),0) FROM bridge_changes") ?? 0
            var chunk: [BridgeRecord] = []
            func flush(final: Bool) throws {
                seq += 1
                try enqueue(chunk, db: db, dataset: dataset, epoch: epoch, started: started, seq: seq, snapshot: true, final: final, since: since, zone: zone, now: now)
                chunk.removeAll(keepingCapacity: true)
            }
            for spec in BridgeWire.tables {
                let rows = try Row.fetchCursor(db, sql: "SELECT *, CAST(\(spec.key) AS TEXT) AS bridge_key FROM \(spec.name) ORDER BY \(spec.key)")
                while let row = try rows.next() {
                    // A snapshot can contain millions of rows in one writer task.
                    // Foundation JSON bridging creates autoreleased temporaries;
                    // drain them here instead of retaining them until task exit.
                    try autoreleasepool {
                        let key: String = row["bridge_key"]
                        let r = try normalized(row, table: spec.name, key: key, since: since, zone: zone)
                        guard r.json != nil else { return }
                        chunk.append(r)
                        if chunk.count == 1000 { try flush(final: false) }
                    }
                }
            }
            try flush(final: true)
        } else {
            let changes = try Row.fetchAll(db, sql: "SELECT * FROM bridge_changes WHERE seq>? ORDER BY seq LIMIT 1000", arguments: [cursor])
            guard !changes.isEmpty else { return }
            var seen = Set<String>(); var records: [BridgeRecord] = []
            for row in changes {
                let table: String = row["entity"]; let key: String = row["record_key"]
                cursor = row["seq"]
                if seen.insert(table + ":" + key).inserted { records.append(try record(db, table: table, key: key, since: since, zone: zone)) }
            }
            seq += 1
            try enqueue(records, db: db, dataset: dataset, epoch: epoch, started: started, seq: seq, snapshot: false, final: false, since: since, zone: zone, now: now)
        }
        try db.execute(sql: "UPDATE bridge_state SET epoch=?,epoch_started=?,history_start=?,timezone=?,cursor=?,sequence=? WHERE id=1", arguments: [epoch, started, since, zone, cursor, seq])
        try db.execute(sql: "DELETE FROM bridge_changes WHERE seq<=?", arguments: [cursor])
    }
    private static func enqueue(_ records: [BridgeRecord], db: Database, dataset: String, epoch: String, started: Double, seq: Int64, snapshot: Bool, final: Bool, since: Double, zone: String, now: Date) throws {
        let payload = try records.reduce(into: Data()) { data, r in data.append(try BridgeWire.encode(r)); data.append(10) }
        let manifest = BridgeManifest(dataset: dataset, epoch: epoch, epochStarted: started, sequence: seq, snapshot: snapshot, finalSnapshot: final, historyStart: since, timeZone: zone, generatedAt: now.timeIntervalSince1970, count: records.count, bytes: payload.count, sha256: BridgeWire.hash(payload))
        try db.execute(sql: "INSERT INTO bridge_outbox(sequence,manifest,payload) VALUES(?,?,?)", arguments: [seq, try BridgeWire.encode(manifest), payload])
    }
    public static func publish(pool: DatabasePool, root: URL) throws -> String {
        try publishPass(pool: pool, root: root).status
    }

    public static func publishPass(pool: DatabasePool, root: URL) throws -> BridgePublishResult {
        try publishPass(
            pool: pool,
            root: root,
            maxPublishBatches: defaultBatchBudget,
            maxMaintenanceBatches: defaultBatchBudget,
            now: Date()
        )
    }

    /// Runs one bounded publication and receipt-maintenance pass.
    ///
    /// Metadata is selected without the payload column. Payload bytes are fetched only when a
    /// batch must be written or replayed. The cursor sidecar is protocol-neutral (the receiver
    /// only scans `batches` and `receipts`) and makes both lanes fair across process restarts.
    static func publishPass(
        pool: DatabasePool,
        root: URL,
        maxPublishBatches: Int,
        maxMaintenanceBatches: Int,
        now: Date,
        onPayloadRead: ((Int64) -> Void)? = nil,
        onMaintenanceVisit: ((Int64) -> Void)? = nil
    ) throws -> BridgePublishResult {
        precondition(maxPublishBatches > 0 && maxMaintenanceBatches > 0)
        let fm = FileManager.default
        let batches = root.appendingPathComponent("batches", isDirectory: true)
        let receipts = root.appendingPathComponent("receipts", isDirectory: true)
        try fm.createDirectory(at: batches, withIntermediateDirectories: true)
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)

        let cursorURL = root.appendingPathComponent(cursorFileName)
        var cursor = readCursor(at: cursorURL)
        var publishedBatchCount = 0
        var acknowledgedBatchCount = 0
        let pendingRows = try metadata(
            pool: pool,
            acknowledged: false,
            after: cursor.pendingAfter,
            limit: maxPublishBatches
        )
        for row in pendingRows {
            let receiptURL = receipts.appendingPathComponent(BridgeWire.folder(row.manifest) + ".json")
            if validReceipt(at: receiptURL, for: row.manifest) {
                try pool.write { db in
                    try db.execute(
                        sql: "UPDATE bridge_outbox SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE sequence=?",
                        arguments: [now.timeIntervalSince1970, row.sequence]
                    )
                }
                acknowledgedBatchCount += 1
                continue
            }

            let directory = batches.appendingPathComponent(BridgeWire.folder(row.manifest), isDirectory: true)
            let payloadURL = directory.appendingPathComponent("records.jsonl")
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard publicationNeedsWrite(
                directory: directory,
                payload: payloadURL,
                manifest: manifestURL,
                now: now
            ) else { continue }

            guard let payload = try pool.read({ db in
                try Data.fetchOne(db, sql: "SELECT payload FROM bridge_outbox WHERE sequence=? AND acknowledged_at IS NULL", arguments: [row.sequence])
            }) else { continue }
            onPayloadRead?(row.sequence)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // An interrupted write is replayed from the durable outbox with identical bytes.
            try BridgeWire.coordinatedWrite(payload, to: payloadURL)
            try BridgeWire.coordinatedWrite(row.manifestData, to: manifestURL)
            publishedBatchCount += 1
        }
        if let last = pendingRows.last { cursor.pendingAfter = last.sequence }

        let maintenanceRows = try metadata(
            pool: pool,
            acknowledged: true,
            after: cursor.maintenanceAfter,
            limit: maxMaintenanceBatches
        )
        for row in maintenanceRows {
            onMaintenanceVisit?(row.sequence)
            let name = BridgeWire.folder(row.manifest)
            let receiptURL = receipts.appendingPathComponent(name + ".json")
            guard validReceipt(at: receiptURL, for: row.manifest),
                  let acknowledgedAt = row.acknowledgedAt,
                  now.timeIntervalSince1970 - acknowledgedAt > 7 * 86_400 else { continue }
            let directory = batches.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            // The validated receipt and manifest remain as a compact ledger.
            try pool.write { db in
                try db.execute(sql: "UPDATE bridge_outbox SET payload=? WHERE sequence=?", arguments: [Data(), row.sequence])
            }
        }
        if let last = maintenanceRows.last { cursor.maintenanceAfter = last.sequence }
        try BridgeWire.coordinatedWrite(try BridgeWire.encode(cursor), to: cursorURL)

        let summary = try pool.read { db -> (pending: Int, received: Int64) in
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bridge_outbox WHERE acknowledged_at IS NULL") ?? 0
            let received = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence),0) FROM bridge_outbox WHERE acknowledged_at IS NOT NULL") ?? 0
            return (pending, received)
        }
        let status = summary.pending == 0
            ? "Mac 已入库（批次 \(summary.received)）"
            : "已生成同步数据，等待 Mac 接收（\(summary.pending) 批）"
        return BridgePublishResult(
            status: status,
            publishedBatchCount: publishedBatchCount,
            acknowledgedBatchCount: acknowledgedBatchCount,
            shouldContinueImmediately: publishedBatchCount + acknowledgedBatchCount == maxPublishBatches
        )
    }

    private static func metadata(
        pool: DatabasePool,
        acknowledged: Bool,
        after cursor: Int64,
        limit: Int
    ) throws -> [OutboxMetadata] {
        try pool.read { db in
            let predicate = acknowledged ? "acknowledged_at IS NOT NULL" : "acknowledged_at IS NULL"
            var rows = try Row.fetchAll(
                db,
                sql: "SELECT sequence,manifest,acknowledged_at FROM bridge_outbox WHERE \(predicate) AND sequence>? ORDER BY sequence LIMIT ?",
                arguments: [cursor, limit]
            )
            if rows.count < limit {
                rows += try Row.fetchAll(
                    db,
                    sql: "SELECT sequence,manifest,acknowledged_at FROM bridge_outbox WHERE \(predicate) AND sequence<=? ORDER BY sequence LIMIT ?",
                    arguments: [cursor, limit - rows.count]
                )
            }
            return try rows.map { row in
                let manifestData: Data = row["manifest"]
                return OutboxMetadata(
                    sequence: row["sequence"],
                    manifestData: manifestData,
                    manifest: try JSONDecoder().decode(BridgeManifest.self, from: manifestData),
                    acknowledgedAt: row["acknowledged_at"]
                )
            }
        }
    }

    private static func readCursor(at url: URL) -> PublishCursor {
        guard let data = try? BridgeWire.coordinatedRead(url),
              let cursor = try? JSONDecoder().decode(PublishCursor.self, from: data) else {
            return PublishCursor()
        }
        return cursor
    }

    private static func validReceipt(at url: URL, for manifest: BridgeManifest) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? BridgeWire.coordinatedRead(url),
              let receipt = try? JSONDecoder().decode(BridgeReceipt.self, from: data) else { return false }
        return receipt.dataset == manifest.dataset
            && receipt.epoch == manifest.epoch
            && receipt.sequence == manifest.sequence
            && receipt.sha256 == manifest.sha256
    }

    private static func publicationNeedsWrite(
        directory: URL,
        payload: URL,
        manifest: URL,
        now: Date
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              fm.fileExists(atPath: payload.path),
              fm.fileExists(atPath: manifest.path) else { return true }
        let dates = [payload, manifest].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard dates.count == 2, let oldest = dates.min() else { return true }
        return now.timeIntervalSince(oldest) >= replayInterval
    }
}
