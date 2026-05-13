import Foundation
import GRDB

struct MissingDataAlert: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "missing_data_alerts"

    enum Severity: String, Codable {
        case info, warning, critical
    }

    var id: Int64?
    var date: String
    var metric: String
    var severity: Severity
    var message: String?
    var acknowledged: Bool
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case metric
        case severity
        case message
        case acknowledged
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
