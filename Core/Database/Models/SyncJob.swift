import Foundation
import GRDB

struct SyncJob: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "sync_jobs"

    enum JobType: String, Codable {
        case backfill, incremental, manual, reconcile
    }

    enum State: String, Codable {
        case pending, running, succeeded, failed
    }

    enum Trigger: String, Codable {
        case user, timer, bgTask = "bg_task", observer, app
    }

    var id: Int64?
    var jobType: JobType
    var state: State
    var trigger: Trigger?
    var startedAt: Int64
    var endedAt: Int64?
    var errorCode: String?
    var errorMessage: String?
    var statsJson: String?
    var attempt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case jobType = "job_type"
        case state
        case trigger
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case statsJson = "stats_json"
        case attempt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
