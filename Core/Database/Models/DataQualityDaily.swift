import Foundation
import GRDB

struct DataQualityDaily: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "data_quality_daily"

    var date: String
    var completenessScore: Double?
    var freshnessScore: Double?
    var conflictScore: Double?
    var missingMetricsJson: String?
    var computedAt: Int64

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case completenessScore = "completeness_score"
        case freshnessScore = "freshness_score"
        case conflictScore = "conflict_score"
        case missingMetricsJson = "missing_metrics_json"
        case computedAt = "computed_at"
    }
}
