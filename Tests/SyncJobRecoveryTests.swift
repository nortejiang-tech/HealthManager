import XCTest
import GRDB
@testable import HealthManager

final class SyncJobRecoveryTests: XCTestCase {
    private let recoveryEpoch: Int64 = 2_000_000

    func test_recoverInterruptedWork_closesActiveJobsAndAssociatedRunningReports() throws {
        let database = DatabaseManager.makeInMemoryForTesting()

        try database.write { db in
            try insertJob(
                db,
                id: 1,
                state: .pending,
                endedAt: nil,
                errorCode: nil,
                errorMessage: nil,
                statsJson: "{\"kept\":1}"
            )
            try insertJob(
                db,
                id: 2,
                state: .running,
                endedAt: 1_500_000,
                errorCode: "old-code",
                errorMessage: "已有诊断",
                statsJson: "{\"kept\":2}"
            )
            try insertJob(
                db,
                id: 3,
                state: .succeeded,
                endedAt: 1_600_000,
                errorCode: nil,
                errorMessage: nil,
                statsJson: "{\"terminal\":true}"
            )
            try insertBackfillReport(
                db,
                id: 10,
                jobId: 1,
                status: .running,
                endedAt: nil,
                errorMessage: nil
            )
            try insertBackfillReport(
                db,
                id: 11,
                jobId: 2,
                status: .running,
                endedAt: 1_400_000,
                errorMessage: "既有回补诊断"
            )
            try insertBackfillReport(
                db,
                id: 12,
                jobId: 3,
                status: .succeeded,
                endedAt: 1_600_000,
                errorMessage: nil
            )
        }

        let outcome = try SyncJobRecovery(database: database).recoverInterruptedWork(
            at: Date(timeIntervalSince1970: TimeInterval(recoveryEpoch))
        )

        XCTAssertEqual(
            outcome,
            .init(recoveredJobCount: 2, recoveredBackfillReportCount: 2)
        )

        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, state, ended_at, error_code, error_message, stats_json
                    FROM sync_jobs
                    ORDER BY id
                    """
            )
        }

        XCTAssertEqual(rows[0]["state"], "failed")
        XCTAssertEqual(rows[0]["ended_at"], recoveryEpoch)
        XCTAssertEqual(rows[0]["error_code"], SyncJobRecovery.interruptionErrorCode)
        XCTAssertEqual(rows[0]["error_message"], SyncJobRecovery.interruptionMessage)
        XCTAssertEqual(rows[0]["stats_json"], "{\"kept\":1}")

        XCTAssertEqual(rows[1]["state"], "failed")
        XCTAssertEqual(rows[1]["ended_at"], Int64(1_500_000))
        XCTAssertEqual(rows[1]["error_code"], SyncJobRecovery.interruptionErrorCode)
        XCTAssertEqual(rows[1]["error_message"], "已有诊断")
        XCTAssertEqual(rows[1]["stats_json"], "{\"kept\":2}")

        XCTAssertEqual(rows[2]["state"], "succeeded")
        XCTAssertEqual(rows[2]["ended_at"], Int64(1_600_000))
        XCTAssertNil(rows[2]["error_code"] as String?)
        XCTAssertNil(rows[2]["error_message"] as String?)
        XCTAssertEqual(rows[2]["stats_json"], "{\"terminal\":true}")

        let reportRows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, status, ended_at, error_message
                    FROM backfill_report
                    ORDER BY id
                    """
            )
        }
        XCTAssertEqual(reportRows[0]["status"], "failed")
        XCTAssertEqual(reportRows[0]["ended_at"], recoveryEpoch)
        XCTAssertEqual(reportRows[0]["error_message"], SyncJobRecovery.interruptionMessage)
        XCTAssertEqual(reportRows[1]["status"], "failed")
        XCTAssertEqual(reportRows[1]["ended_at"], Int64(1_400_000))
        XCTAssertEqual(reportRows[1]["error_message"], "既有回补诊断")
        XCTAssertEqual(reportRows[2]["status"], "succeeded")
        XCTAssertEqual(reportRows[2]["ended_at"], Int64(1_600_000))
        XCTAssertNil(reportRows[2]["error_message"] as String?)
    }

    func test_recoverInterruptedWork_isIdempotentAndNoOpsWithoutActiveRows() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            try insertJob(
                db,
                id: 1,
                state: .running,
                endedAt: nil,
                errorCode: nil,
                errorMessage: nil,
                statsJson: nil
            )
        }

        let recovery = SyncJobRecovery(database: database)
        let date = Date(timeIntervalSince1970: TimeInterval(recoveryEpoch))

        XCTAssertEqual(
            try recovery.recoverInterruptedWork(at: date),
            .init(recoveredJobCount: 1, recoveredBackfillReportCount: 0)
        )
        XCTAssertEqual(
            try recovery.recoverInterruptedWork(at: date.addingTimeInterval(60)),
            .init(recoveredJobCount: 0, recoveredBackfillReportCount: 0)
        )

        let endedAt = try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT ended_at FROM sync_jobs WHERE id = 1")
        }
        XCTAssertEqual(endedAt, recoveryEpoch)
    }

    private func insertJob(
        _ db: Database,
        id: Int64,
        state: SyncJob.State,
        endedAt: Int64?,
        errorCode: String?,
        errorMessage: String?,
        statsJson: String?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_jobs
                  (id, job_type, state, trigger, started_at, ended_at,
                   error_code, error_message, stats_json, attempt)
                VALUES (?, 'incremental', ?, 'observer', 1_000_000, ?, ?, ?, ?, 1)
                """,
            arguments: [id, state.rawValue, endedAt, errorCode, errorMessage, statsJson]
        )
    }

    private func insertBackfillReport(
        _ db: Database,
        id: Int64,
        jobId: Int64,
        status: BackfillReport.Status,
        endedAt: Int64?,
        errorMessage: String?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO backfill_report
                  (id, job_id, started_at, ended_at, requested_days, hk_type,
                   sample_count, missing, status, error_message,
                   coverage_summary_json, created_at)
                VALUES (?, ?, 1_000_000, ?, 30, 'sample-type', 0, 1, ?, ?, NULL, 1_000_000)
                """,
            arguments: [id, jobId, endedAt, status.rawValue, errorMessage]
        )
    }
}
