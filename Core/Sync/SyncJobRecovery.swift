import Foundation
import GRDB

/// Repairs durable job envelopes left active when the previous app process exited.
///
/// Call exactly once at process bootstrap, before any coordinator is allowed to create a
/// new job. At that point every existing `pending` / `running` row necessarily belongs to
/// an earlier process and can be closed without racing current work.
struct SyncJobRecovery {
    struct Outcome: Equatable, Sendable {
        let recoveredJobCount: Int
        let recoveredBackfillReportCount: Int
    }

    static let interruptionErrorCode = "interrupted_before_completion"
    static let interruptionMessage = "上次同步在完成前中断，已在本次启动时标记为失败。"

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func recoverInterruptedWork(at recoveryDate: Date = Date()) throws -> Outcome {
        let recoveryEpoch = Int64(recoveryDate.timeIntervalSince1970)

        return try database.write { db in
            // DatabasePool.write already wraps this closure in one transaction. Keeping both
            // updates in the same closure makes the report/job transition atomic without a
            // nested BEGIN, which SQLite rejects.
            try db.execute(
                sql: """
                    UPDATE backfill_report
                    SET status = ?,
                        ended_at = COALESCE(ended_at, ?),
                        error_message = CASE
                            WHEN error_message IS NULL OR TRIM(error_message) = '' THEN ?
                            ELSE error_message
                        END
                    WHERE status = ?
                      AND job_id IN (
                          SELECT id
                          FROM sync_jobs
                          WHERE state IN (?, ?)
                      )
                    """,
                arguments: [
                    BackfillReport.Status.failed.rawValue,
                    recoveryEpoch,
                    Self.interruptionMessage,
                    BackfillReport.Status.running.rawValue,
                    SyncJob.State.pending.rawValue,
                    SyncJob.State.running.rawValue
                ]
            )
            let recoveredBackfillReportCount = db.changesCount

            try db.execute(
                sql: """
                    UPDATE sync_jobs
                    SET state = ?,
                        ended_at = COALESCE(ended_at, ?),
                        error_code = ?,
                        error_message = CASE
                            WHEN error_message IS NULL OR TRIM(error_message) = '' THEN ?
                            ELSE error_message
                        END
                    WHERE state IN (?, ?)
                    """,
                arguments: [
                    SyncJob.State.failed.rawValue,
                    recoveryEpoch,
                    Self.interruptionErrorCode,
                    Self.interruptionMessage,
                    SyncJob.State.pending.rawValue,
                    SyncJob.State.running.rawValue
                ]
            )

            return Outcome(
                recoveredJobCount: db.changesCount,
                recoveredBackfillReportCount: recoveredBackfillReportCount
            )
        }
    }
}
