import Foundation
import GRDB

struct MealItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "meal_items"

    enum PreparationState: String, Codable, CaseIterable {
        case unknown
        case raw
        case cooked
    }

    enum ProvenanceKind: String, Codable, CaseIterable {
        case manual
        case aiEstimate = "ai_estimate"
        case nutritionDatabase = "nutrition_database"
        case nutritionLabel = "nutrition_label"
    }

    enum Confidence: String, Codable, CaseIterable {
        case low
        case medium
        case high
    }

    var id: Int64?
    var mealId: Int64
    var sortOrder: Int
    var name: String
    var grams: Double?
    var preparationState: PreparationState
    var caloriesKcal: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var provenanceKind: ProvenanceKind
    var provenanceRef: String?
    var provenanceVersion: String?
    var confidence: Confidence?
    var isUserEdited: Bool
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case mealId = "meal_id"
        case sortOrder = "sort_order"
        case name
        case grams
        case preparationState = "preparation_state"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case provenanceKind = "provenance_kind"
        case provenanceRef = "provenance_ref"
        case provenanceVersion = "provenance_version"
        case confidence
        case isUserEdited = "is_user_edited"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
