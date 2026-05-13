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
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
