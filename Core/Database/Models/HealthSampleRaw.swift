import Foundation
import GRDB

struct HealthSampleRaw: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "health_samples_raw"

    enum Kind: String, Codable {
        case quantity, category, workout
    }

    var sampleUUID: String
    var hkType: String
    var kind: Kind
    var value: Double
    var unit: String
    var startAt: Int64
    var endAt: Int64
    var sourceName: String?
    var sourceBundleId: String?
    var deviceName: String?
    var deviceModel: String?
    var ingestedAt: Int64
    var isDeleted: Bool
    var extraJson: String?

    enum CodingKeys: String, CodingKey {
        case sampleUUID = "sample_uuid"
        case hkType = "hk_type"
        case kind
        case value
        case unit
        case startAt = "start_at"
        case endAt = "end_at"
        case sourceName = "source_name"
        case sourceBundleId = "source_bundle_id"
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case ingestedAt = "ingested_at"
        case isDeleted = "is_deleted"
        case extraJson = "extra_json"
    }
}
