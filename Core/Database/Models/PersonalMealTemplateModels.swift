import Foundation
import GRDB

/// A factual meal-item snapshot inside a reusable personal dish. Nutrition and provenance
/// stay exactly as saved in the editor; a template never reinterprets an AI estimate.
struct PersonalMealTemplateItem: Codable, Equatable, Sendable {
    var name: String
    var grams: Double?
    var preparationState: MealItemRecord.PreparationState
    var caloriesKcal: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var provenanceKind: MealItemRecord.ProvenanceKind
    var provenanceRef: String?
    var provenanceVersion: String?
    var confidence: MealItemRecord.Confidence?
    var isUserEdited: Bool

    enum CodingKeys: String, CodingKey {
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
    }

    init(item: MealStore.ItemInput) {
        name = item.name
        grams = item.grams
        preparationState = item.preparationState
        caloriesKcal = item.caloriesKcal
        proteinG = item.proteinG
        fatG = item.fatG
        carbsG = item.carbsG
        provenanceKind = item.provenanceKind
        provenanceRef = item.provenanceRef
        provenanceVersion = item.provenanceVersion
        confidence = item.confidence
        isUserEdited = item.isUserEdited
    }

    func itemInput() -> MealStore.ItemInput {
        MealStore.ItemInput(
            name: name,
            grams: grams,
            preparationState: preparationState,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            provenanceKind: provenanceKind,
            provenanceRef: provenanceRef,
            provenanceVersion: provenanceVersion,
            confidence: confidence,
            isUserEdited: isUserEdited
        )
    }
}

struct PersonalMealTemplateRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "personal_meal_templates"

    var id: Int64?
    var displayName: String
    var itemsJSON: String
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case itemsJSON = "items_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
