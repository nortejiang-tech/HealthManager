import Foundation
import GRDB

/// sync_jobs 信封的唯一入口。
///
/// 此前 open/close 语义（state 字符串、stats JSON、error 列）在
/// Backfill / Incremental / Manual / DailyReconciler 四个 coordinator 里
/// 逐字复制；修改 job 语义要同步改四处。现在集中于此。
struct SyncJobRecorder {
    let database: DatabaseManager

    /// 打开一条 running 状态的 job 信封，返回 job id。
    func openJob(
        jobType: SyncJob.JobType,
        trigger: SyncJob.Trigger,
        startedAt: Date
    ) throws -> Int64 {
        var job = SyncJob(
            id: nil,
            jobType: jobType,
            state: .running,
            trigger: trigger,
            startedAt: Int64(startedAt.timeIntervalSince1970),
            endedAt: nil,
            errorCode: nil,
            errorMessage: nil,
            statsJson: nil,
            attempt: 1
        )
        try database.write { db in
            try job.insert(db)
        }
        guard let id = job.id else {
            throw NSError(domain: "SyncJobRecorder", code: -1)
        }
        return id
    }

    /// 关闭一条 job 信封：写入终态、结束时间、错误与统计。
    func closeJob(
        id: Int64,
        endedAt: Date,
        succeeded: Bool,
        errorMessage: String?,
        stats: [String: Int]
    ) throws {
        let statsData = try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
        let statsJson = String(data: statsData, encoding: .utf8)
        let state = succeeded
            ? SyncJob.State.succeeded.rawValue
            : SyncJob.State.failed.rawValue

        try database.write { db in
            try db.execute(sql: """
                UPDATE sync_jobs
                SET state = ?, ended_at = ?, error_message = ?, stats_json = ?
                WHERE id = ?
                """, arguments: [
                    state,
                    Int64(endedAt.timeIntervalSince1970),
                    errorMessage,
                    statsJson,
                    id
                ])
        }
    }
}
