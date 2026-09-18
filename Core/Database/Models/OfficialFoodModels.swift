import Foundation
import GRDB

/// 官方食品身份（ADR-005）：provider + 官方 food ID 唯一。
/// 中文名/别名差异不产生新身份；同一身份可有多个不可变资料版本。
struct OfficialFoodRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "official_foods"

    var id: Int64?
    var provider: String
    var providerFoodId: String
    var nameOriginal: String
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case providerFoodId = "provider_food_id"
        case nameOriginal = "name_original"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 不可变资料版本：更新官方数据产生新行，旧行不改写。
/// `versionLabel` 有官方版本号时用官方版本，没有时用 `fetched:<抓取时间>:<内容摘要前8位>`
/// 识别快照，不伪造版本。
struct OfficialFoodVersionRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "official_food_versions"

    var id: Int64?
    var officialFoodId: Int64
    var versionLabel: String
    /// FoodCatalogBasis rawValue：per100g / per100mL。
    var basis: String
    /// FoodCatalogEntry.Nutrients 的 JSON 快照（含 measured/estimated/trace/unmeasured 标记）。
    var nutrientsJSON: String
    var displayNameZh: String
    /// FoodCatalogCategory rawValue。
    var category: String
    /// MealItemRecord.PreparationState rawValue。
    var preparationState: String
    var refusePercent: Double?
    var sourceUrl: String
    var sourceEdition: String
    var note: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case officialFoodId = "official_food_id"
        case versionLabel = "version_label"
        case basis
        case nutrientsJSON = "nutrients_json"
        case displayNameZh = "display_name_zh"
        case category
        case preparationState = "preparation_state"
        case refusePercent = "refuse_percent"
        case sourceUrl = "source_url"
        case sourceEdition = "source_edition"
        case note
        case createdAt = "created_at"
    }

    var nutrients: FoodCatalogEntry.Nutrients? {
        guard let data = nutrientsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FoodCatalogEntry.Nutrients.self, from: data)
    }

    var foodCatalogBasis: FoodCatalogBasis {
        FoodCatalogBasis(rawValue: basis) ?? .per100g
    }

    var foodCatalogCategory: FoodCatalogCategory {
        FoodCatalogCategory(rawValue: category) ?? .oilSeasoning
    }

    var preparation: FoodCatalogPreparationState {
        FoodCatalogPreparationState(rawValue: preparationState) ?? .unknown
    }

    static func encodeNutrients(_ nutrients: FoodCatalogEntry.Nutrients) -> String {
        guard let data = try? JSONEncoder().encode(nutrients) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 由版本快照合成目录条目形态（详情页/草稿工厂共用）。
    /// `stableId` = "<provider 小写>-<官方 food ID>"，与离线目录的 mext-XXXXX 形态一致。
    func catalogEntry(food: OfficialFoodRecord, displayName: String) -> FoodCatalogEntry? {
        guard let nutrients else { return nil }
        return FoodCatalogEntry(
            id: Self.stableIdentity(provider: food.provider, providerFoodId: food.providerFoodId),
            source: food.provider,
            foodNo: food.providerFoodId,
            foodGroup: "db",
            nameZh: displayName,
            nameOriginal: food.nameOriginal,
            aliases: [],
            category: foodCatalogCategory,
            preparationState: preparation,
            basis: foodCatalogBasis,
            refusePercent: refusePercent,
            nutrients: nutrients,
            sourceUrl: sourceUrl,
            note: note ?? ""
        )
    }

    static func stableIdentity(provider: String, providerFoodId: String) -> String {
        "\(provider.lowercased())-\(providerFoodId)"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 「我的参考表」成员：移除是 `is_removed` 状态变化；重新添加恢复成员。
struct PersonalReferenceEntryRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "personal_reference_entries"

    var id: Int64?
    var officialFoodId: Int64
    /// 成员选用的资料版本（不可变快照指针）。
    var versionId: Int64
    var displayName: String
    var customAliasesJSON: String
    var isRemoved: Bool
    var addedAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case officialFoodId = "official_food_id"
        case versionId = "version_id"
        case displayName = "display_name"
        case customAliasesJSON = "custom_aliases_json"
        case isRemoved = "is_removed"
        case addedAt = "added_at"
        case updatedAt = "updated_at"
    }

    var customAliases: [String] {
        guard let data = customAliasesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodeAliases(_ aliases: [String]) -> String {
        guard let data = try? JSONEncoder().encode(aliases) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
