import Foundation
import GRDB

struct BackfillReport: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "backfill_report"

    enum Status: String, Codable {
        case running, succeeded, failed, skipped
    }

    var id: Int64?
    var jobId: Int64?
    var startedAt: Int64
    var endedAt: Int64?
    var requestedDays: Int
    var hkType: String
    var sampleCount: Int
    var missing: Bool
    var status: Status
    var errorMessage: String?
    var coverageSummaryJson: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case jobId = "job_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case requestedDays = "requested_days"
        case hkType = "hk_type"
        case sampleCount = "sample_count"
        case missing
        case status
        case errorMessage = "error_message"
        case coverageSummaryJson = "coverage_summary_json"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
