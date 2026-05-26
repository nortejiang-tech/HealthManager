import Foundation
import GRDB

struct MealRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "meal_records"

    enum MealType: String, Codable, CaseIterable {
        case breakfast, lunch, dinner, snack

        var label: String {
            switch self {
            case .breakfast: return "早餐"
            case .lunch: return "午餐"
            case .dinner: return "晚餐"
            case .snack: return "加餐"
            }
        }

        /// Pick a sensible default meal kind based on wall-clock hour.
        static func suggested(for date: Date = Date(),
                              calendar: Calendar = .current) -> MealType {
            switch calendar.component(.hour, from: date) {
            case 4..<10: return .breakfast
            case 10..<14: return .lunch
            case 17..<22: return .dinner
            default: return .snack
            }
        }
    }

    var id: Int64?
    var mealType: MealType
    var eatenAt: Int64
    var caloriesKcal: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var photoPath: String?
    var notes: String?
    var createdAt: Int64
    /// Per-meal id stamped onto the HealthKit nutrition samples we wrote for this meal.
    /// nil when the meal was never synced to Apple Health.
    var hkSyncId: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case mealType = "meal_type"
        case eatenAt = "eaten_at"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case photoPath = "photo_path"
        case notes
        case createdAt = "created_at"
        case hkSyncId = "hk_sync_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
