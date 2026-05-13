import Foundation
import GRDB

struct MedicationPlan: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "medication_plans"

    enum Frequency: String, Codable, CaseIterable {
        case weekly, biweekly, custom

        var label: String {
            switch self {
            case .weekly: return "每周"
            case .biweekly: return "每两周"
            case .custom: return "自定义"
            }
        }
    }

    var id: Int64?
    var name: String
    var dosageMg: Double?
    var frequency: String?
    var scheduleJson: String?
    var startDate: String?
    var endDate: String?
    var reminderEnabled: Bool
    var notes: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case dosageMg = "dosage_mg"
        case frequency
        case scheduleJson = "schedule_json"
        case startDate = "start_date"
        case endDate = "end_date"
        case reminderEnabled = "reminder_enabled"
        case notes
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
