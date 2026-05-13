import Foundation
import GRDB

struct DailySummary: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "daily_summaries"

    var date: String
    var summaryText: String?
    var keyFindingsJson: String?
    var qualityScore: Double?
    var generatedAt: Int64

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case summaryText = "summary_text"
        case keyFindingsJson = "key_findings_json"
        case qualityScore = "quality_score"
        case generatedAt = "generated_at"
    }
}

struct WeeklySummary: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "weekly_summaries"

    var weekStartDate: String
    var summaryText: String?
    var findingsJson: String?
    var qualityScore: Double?
    var generatedAt: Int64

    var id: String { weekStartDate }

    enum CodingKeys: String, CodingKey {
        case weekStartDate = "week_start_date"
        case summaryText = "summary_text"
        case findingsJson = "findings_json"
        case qualityScore = "quality_score"
        case generatedAt = "generated_at"
    }
}
