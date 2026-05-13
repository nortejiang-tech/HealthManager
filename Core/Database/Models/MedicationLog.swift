import Foundation
import GRDB

struct MedicationLog: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "medication_logs"

    enum Action: String, Codable, CaseIterable {
        case taken, skipped, deferred

        var label: String {
            switch self {
            case .taken: return "已服用"
            case .skipped: return "跳过"
            case .deferred: return "延后"
            }
        }
    }

    var id: Int64?
    var planId: Int64?
    var scheduledAt: Int64
    var action: Action
    var actionAt: Int64?
    var dosageMg: Double?
    var sideEffects: String?
    var notes: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case planId = "plan_id"
        case scheduledAt = "scheduled_at"
        case action
        case actionAt = "action_at"
        case dosageMg = "dosage_mg"
        case sideEffects = "side_effects"
        case notes
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
