import Foundation
import GRDB

struct SyncAnchor: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_anchors"

    var hkType: String
    var anchorData: Data
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case hkType = "hk_type"
        case anchorData = "anchor_data"
        case updatedAt = "updated_at"
    }
}
