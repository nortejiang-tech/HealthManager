import XCTest
import GRDB
@testable import HealthManager

/// SyncJobRecorder 是 sync_jobs 信封的唯一入口；此前同一逻辑在 4 个 coordinator 复制。
final class SyncJobRecorderTests: XCTestCase {

    private var database: DatabaseManager!
    private var recorder: SyncJobRecorder!

    override func setUp() async throws {
        database = DatabaseManager.makeInMemoryForTesting()
        recorder = SyncJobRecorder(database: database)
    }

    override func tearDown() async throws {
        database = nil
        recorder = nil
    }

    func test_openJob_writesRunningEnvelope() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let id = try recorder.openJob(jobType: .backfill, trigger: .user, startedAt: startedAt)

        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_jobs WHERE id = ?", arguments: [id])
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["job_type"], "backfill")
        XCTAssertEqual(row?["state"], "running")
        XCTAssertEqual(row?["trigger"], "user")
        XCTAssertEqual(row?["started_at"], 1_000)
        XCTAssertEqual(row?["attempt"], 1)
    }

    func test_openJob_assignsDistinctIds() throws {
        let now = Date()
        let id1 = try recorder.openJob(jobType: .incremental, trigger: .timer, startedAt: now)
        let id2 = try recorder.openJob(jobType: .incremental, trigger: .timer, startedAt: now)
        XCTAssertNotEqual(id1, id2)
    }

    func test_closeJob_succeeded_writesStateAndStats() throws {
        let id = try recorder.openJob(jobType: .manual, trigger: .user, startedAt: Date())
        try recorder.closeJob(
            id: id,
            endedAt: Date(timeIntervalSince1970: 2_000),
            succeeded: true,
            errorMessage: nil,
            stats: ["steps": 42, "meals": 3]
        )

        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_jobs WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["state"], "succeeded")
        XCTAssertEqual(row?["ended_at"], 2_000)
        let stats = try XCTUnwrap(row?["stats_json"] as? String)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stats.utf8)) as? [String: Int])
        XCTAssertEqual(dict, ["steps": 42, "meals": 3])
    }

    func test_closeJob_failed_writesStateAndError() throws {
        let id = try recorder.openJob(jobType: .reconcile, trigger: .bgTask, startedAt: Date())
        try recorder.closeJob(
            id: id,
            endedAt: Date(timeIntervalSince1970: 3_000),
            succeeded: false,
            errorMessage: "boom",
            stats: [:]
        )

        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_jobs WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["state"], "failed")
        XCTAssertEqual(row?["error_message"], "boom")
    }

    func test_closeJob_emptyStats_roundTripsAsEmptyObject() throws {
        let id = try recorder.openJob(jobType: .backfill, trigger: .observer, startedAt: Date())
        try recorder.closeJob(
            id: id,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil,
            stats: [:]
        )
        let statsJson = try database.read { db in
            try String.fetchOne(db, sql: "SELECT stats_json FROM sync_jobs WHERE id = ?", arguments: [id])
        }
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(statsJson).utf8)) as? [String: Int])
        XCTAssertEqual(dict, [:])
    }
}
