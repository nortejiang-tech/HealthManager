import Foundation
import GRDB

public final class BridgeStore: @unchecked Sendable {
    public let pool: DatabasePool
    public init(path: String) throws {
        var config = Configuration(); config.busyMode = .timeout(5)
        pool = try DatabasePool(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("bridge_store_v1") { db in
            try db.execute(sql: """
            CREATE TABLE replica (epoch TEXT NOT NULL, entity TEXT NOT NULL, record_key TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(epoch,entity,record_key));
            CREATE INDEX replica_time ON replica(epoch,entity,json_extract(json,'$.start_at'));
            CREATE INDEX replica_type ON replica(epoch,entity,json_extract(json,'$.hk_type'));
            CREATE TABLE epochs (epoch TEXT PRIMARY KEY, dataset TEXT NOT NULL, started REAL NOT NULL, sequence INTEGER NOT NULL DEFAULT 0, complete INTEGER NOT NULL DEFAULT 0, history_start REAL NOT NULL, timezone TEXT NOT NULL, generated_at REAL NOT NULL, received_at REAL NOT NULL);
            CREATE TABLE receipts (epoch TEXT NOT NULL, sequence INTEGER NOT NULL, hash TEXT NOT NULL, received_at REAL NOT NULL, PRIMARY KEY(epoch,sequence));
            CREATE TABLE receiver_state (id INTEGER PRIMARY KEY CHECK(id=1), dataset TEXT, active_epoch TEXT, last_scan REAL, last_error TEXT, pending INTEGER NOT NULL DEFAULT 0);
            INSERT INTO receiver_state(id) VALUES(1);
            """)
        }
        try migrator.migrate(pool)
    }
    public func ingest(manifest m: BridgeManifest, payload: Data, now: Date = Date()) throws -> BridgeReceipt {
        guard m.version == 1, BridgeWire.validID(m.dataset), BridgeWire.validID(m.epoch), m.sequence > 0,
              m.count >= 0, m.count <= 1000, payload.count <= 64 * 1024 * 1024,
              m.bytes == payload.count, m.sha256 == BridgeWire.hash(payload),
              TimeZone(identifier: m.timeZone) != nil, m.epochStarted.isFinite, m.historyStart.isFinite,
              m.generatedAt.isFinite, !(m.finalSnapshot && !m.snapshot) else { throw BridgeError.invalid("批次版本、长度、摘要或范围无效") }
        let lines = payload.split(separator: 10)
        guard lines.count == m.count else { throw BridgeError.invalid("记录数与 manifest 不符") }
        let records = try lines.map { try JSONDecoder().decode(BridgeRecord.self, from: Data($0)) }
        for r in records {
            guard let spec = BridgeWire.tables.first(where: { $0.name == r.table }), !r.key.isEmpty, r.key.count < 256 else { throw BridgeError.invalid("未知实体或无效主键") }
            if let json = r.json {
                guard let data = json.data(using: .utf8), let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["photo_path"] == nil, let id = obj[spec.key], String(describing: id) == r.key else { throw BridgeError.invalid("记录主键或字段无效") }
            }
        }
        return try pool.write { db in
            let state = try Row.fetchOne(db, sql: "SELECT * FROM receiver_state WHERE id=1")!
            let dataset: String? = state["dataset"]
            guard dataset == nil || dataset == m.dataset else { throw BridgeError.invalid("数据源不匹配，需显式绑定新数据源") }
            if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM receipts WHERE epoch=? AND sequence=?", arguments: [m.epoch, m.sequence]) {
                let hash: String = receipt["hash"]
                guard hash == m.sha256 else { throw BridgeError.invalid("同一批次出现不同内容") }
                return BridgeReceipt(dataset: m.dataset, epoch: m.epoch, sequence: m.sequence, sha256: hash, receivedAt: receipt["received_at"])
            }
            let latest = try Double.fetchOne(db, sql: "SELECT MAX(started) FROM epochs")
            guard latest == nil || m.epochStarted >= latest! else { throw BridgeError.invalid("旧同步世代已被替代") }
            var epoch = try Row.fetchOne(db, sql: "SELECT * FROM epochs WHERE epoch=?", arguments: [m.epoch])
            if epoch == nil {
                guard m.sequence == 1 && m.snapshot else { throw BridgeError.invalid("等待完整快照的首批") }
                if let latest, m.epochStarted <= latest { throw BridgeError.invalid("同步世代时间冲突") }
                try db.execute(sql: "INSERT INTO epochs(epoch,dataset,started,history_start,timezone,generated_at,received_at) VALUES(?,?,?,?,?,?,?)", arguments: [m.epoch,m.dataset,m.epochStarted,m.historyStart,m.timeZone,m.generatedAt,now.timeIntervalSince1970])
                try db.execute(sql: "UPDATE receiver_state SET dataset=? WHERE id=1", arguments: [m.dataset])
                epoch = try Row.fetchOne(db, sql: "SELECT * FROM epochs WHERE epoch=?", arguments: [m.epoch])
            }
            let last: Int64 = epoch!["sequence"]; let complete: Bool = epoch!["complete"]
            let start: Double = epoch!["started"]; let zone: String = epoch!["timezone"]; let history: Double = epoch!["history_start"]
            guard last + 1 == m.sequence, start == m.epochStarted, zone == m.timeZone, history == m.historyStart,
                  m.snapshot != complete else { throw BridgeError.invalid("批次缺口或快照阶段不匹配") }
            for r in records {
                if let json = r.json {
                    try db.execute(sql: "INSERT INTO replica VALUES(?,?,?,?) ON CONFLICT(epoch,entity,record_key) DO UPDATE SET json=excluded.json", arguments: [m.epoch,r.table,r.key,json])
                } else {
                    try db.execute(sql: "DELETE FROM replica WHERE epoch=? AND entity=? AND record_key=?", arguments: [m.epoch,r.table,r.key])
                }
            }
            try db.execute(sql: "UPDATE epochs SET sequence=?,complete=?,generated_at=?,received_at=? WHERE epoch=?", arguments: [m.sequence, complete || m.finalSnapshot,m.generatedAt,now.timeIntervalSince1970,m.epoch])
            if m.finalSnapshot { try db.execute(sql: "UPDATE receiver_state SET active_epoch=? WHERE id=1", arguments: [m.epoch]) }
            try db.execute(sql: "INSERT INTO receipts VALUES(?,?,?,?)", arguments: [m.epoch,m.sequence,m.sha256,now.timeIntervalSince1970])
            return BridgeReceipt(dataset: m.dataset, epoch: m.epoch, sequence: m.sequence, sha256: m.sha256, receivedAt: now.timeIntervalSince1970)
        }
    }
    @discardableResult public func scan(root: URL) throws -> Int {
        let fm = FileManager.default
        let batches = root.appendingPathComponent("batches")
        guard fm.fileExists(atPath: batches.path) else {
            try pool.write { try $0.execute(sql: "UPDATE receiver_state SET last_scan=?,last_error='等待手机首次导出',pending=0 WHERE id=1", arguments: [Date().timeIntervalSince1970]) }; return 0
        }
        let urls = try fm.contentsOfDirectory(at: batches, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var candidates: [(URL, BridgeManifest)] = []; var errors: [String] = []
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isDirectoryKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let data = try BridgeWire.coordinatedRead(url.appendingPathComponent("manifest.json"))
                guard data.count < 65536 else { throw BridgeError.invalid("Manifest too large") }
                let m = try JSONDecoder().decode(BridgeManifest.self, from: data)
                guard BridgeWire.folder(m) == url.lastPathComponent else { throw BridgeError.invalid("批次目录身份不符") }
                candidates.append((url,m))
            } catch { errors.append("批次尚未可读或格式无效") }
        }
        candidates.sort { $0.1.epochStarted == $1.1.epochStarted ? $0.1.sequence < $1.1.sequence : $0.1.epochStarted < $1.1.epochStarted }
        let receipts = root.appendingPathComponent("receipts")
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)
        var count = 0
        for (url,m) in candidates {
            do {
                // Receipt replay does not require the already-pruned payload.
                let existing = try pool.read { try Row.fetchOne($0, sql: "SELECT * FROM receipts WHERE epoch=? AND sequence=?", arguments: [m.epoch,m.sequence]) }
                let receipt: BridgeReceipt
                if let existing {
                    let hash: String = existing["hash"]
                    guard hash == m.sha256 else { throw BridgeError.invalid("批次摘要冲突") }
                    receipt = BridgeReceipt(dataset: m.dataset, epoch: m.epoch, sequence: m.sequence, sha256: hash, receivedAt: existing["received_at"])
                } else {
                    let payloadURL = url.appendingPathComponent("records.jsonl")
                    let size = try payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 64 * 1024 * 1024 else { throw BridgeError.invalid("批次过大") }
                    receipt = try ingest(manifest: m, payload: BridgeWire.coordinatedRead(payloadURL)); count += 1
                }
                let output = receipts.appendingPathComponent(BridgeWire.folder(m) + ".json")
                let receiptData = try BridgeWire.encode(receipt)
                if (try? BridgeWire.coordinatedRead(output)) != receiptData { try BridgeWire.coordinatedWrite(receiptData, to: output) }
            } catch { errors.append(error.localizedDescription) }
        }
        try pool.write { try $0.execute(sql: "UPDATE receiver_state SET last_scan=?,last_error=?,pending=? WHERE id=1", arguments: [Date().timeIntervalSince1970,errors.first,errors.count]) }
        return count
    }
}
