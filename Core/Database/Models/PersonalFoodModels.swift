import Foundation
import GRDB

/// 个人映射（ADR-004 §2.4）：候选名 → 官方条目 / 个人配方的确认关系。
/// 用户创作数据，随备份包 formatVersion 2 导出；目录更新不影响本表。
struct PersonalFoodRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "personal_foods"

    enum Kind: String, Codable, CaseIterable {
        case catalog
        case recipe
    }

    var id: Int64?
    var kind: Kind
    var displayName: String
    /// 覆盖的候选规范名（MealItemIdentity.canonicalName）列表，JSON 数组。
    var matchKeysJSON: String
    var catalogEntryId: String?
    var catalogVersion: String?
    var recipeId: Int64?
    var defaultGrams: Double?
    var pinned: Bool
    var confirmedAt: Int64
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case matchKeysJSON = "match_keys_json"
        case catalogEntryId = "catalog_entry_id"
        case catalogVersion = "catalog_version"
        case recipeId = "recipe_id"
        case defaultGrams = "default_grams"
        case pinned
        case confirmedAt = "confirmed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var matchKeys: [String] {
        guard let data = matchKeysJSON.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return keys
    }

    static func encodeMatchKeys(_ keys: [String]) -> String {
        guard let data = try? JSONEncoder().encode(keys) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 个人配方主体。修改配方生成新版本（personal_recipe_versions），本表只指向当前版本。
struct PersonalRecipeRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "personal_recipes"

    var id: Int64?
    var displayName: String
    var currentVersion: Int
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case currentVersion = "current_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 配方的不可变版本快照。已保存餐次通过 provenance_ref 引用具体版本，
/// 配方修订不回写历史（ADR-004 §2.4）。
struct PersonalRecipeVersionRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "personal_recipe_versions"

    var id: Int64?
    var recipeId: Int64
    var version: Int
    /// RecipeIngredient 数组的 JSON 快照（含条目 id、版本、名称与克数）。
    var ingredientsJSON: String
    /// 最终可食成品重量；nil = 待补（此时不给每 100 g）。
    var outputGrams: Double?
    /// weighed = 实称；estimated = 用户明确估计。
    var outputWeightBasis: String?
    var note: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case recipeId = "recipe_id"
        case version
        case ingredientsJSON = "ingredients_json"
        case outputGrams = "output_grams"
        case outputWeightBasis = "output_weight_basis"
        case note
        case createdAt = "created_at"
    }

    var ingredients: [RecipeIngredient] {
        guard let data = ingredientsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RecipeIngredient].self, from: data)) ?? []
    }

    static func encodeIngredients(_ ingredients: [RecipeIngredient]) throws -> String {
        let data = try JSONEncoder().encode(ingredients)
        return String(decoding: data, as: UTF8.self)
    }

    var outputBasisDisplay: String? {
        switch outputWeightBasis {
        case "weighed": return "实称"
        case "estimated": return "估计"
        default: return nil
        }
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 被用户忽略的常吃候选；不再在「我的常吃」自动重现。
struct IgnoredCandidateRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "ignored_candidates"

    var candidateKey: String
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case candidateKey = "candidate_key"
        case createdAt = "created_at"
    }
}
