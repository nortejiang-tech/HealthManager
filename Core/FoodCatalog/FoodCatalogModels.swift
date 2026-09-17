import Foundation

/// 离线官方营养目录（ADR-004）。
///
/// 目录是**只读、可版本化的应用资源**：不是用户数据，不进备份包；
/// 目录更新不改变任何已保存餐次的历史快照（ADR-001）。
/// 条目身份 = 来源机构 + 食品编号（`id`），绝不以中文名做唯一键。
struct FoodCatalog: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var source: SourceInfo
    var entries: [FoodCatalogEntry]
}

extension FoodCatalog {
    struct SourceInfo: Codable, Equatable, Sendable {
        var agency: String
        var title: String
        var edition: String
        var downloadUrl: String
        var errataUrl: String?
        var downloadedAt: String
        var fileSha256: String
        var termsOfUse: String
    }
}

/// 单条官方食物条目。数值一律「每 100 g（或 100 mL）可食部分」。
struct FoodCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String
    var foodNo: String
    var foodGroup: String
    var nameZh: String
    var nameOriginal: String
    /// 已审核的中文搜索别名；只用于查找，不构成“同名即同物”的自动匹配。
    var aliases: [String]
    var category: FoodCatalogCategory
    var preparationState: FoodCatalogPreparationState
    /// 数值口径：per100g（固体/默认）或 per100mL（饮料，密度未证实时不得换算）。
    var basis: FoodCatalogBasis
    /// 官方废弃率（蛋壳/玉米芯等），仅展示；可食部数值已按废弃率折算，勿重复扣除。
    var refusePercent: Double?
    var nutrients: Nutrients
    var sourceUrl: String
    var note: String

    var displayName: String { nameZh }

    /// 详情页「查看来源」使用；机构 + 食品编号 + 版本即使链接失效也可理解原记录。
    var sourceCitation: String {
        "\(source) \(sourceEditionHint) · 食品番号 \(foodNo)"
    }

    private var sourceEditionHint: String {
        "官方成分表"
    }
}

extension FoodCatalogEntry {
    struct Nutrients: Codable, Equatable, Sendable {
        var kcal: FoodCatalogNutrient
        var proteinG: FoodCatalogNutrient
        var fatG: FoodCatalogNutrient
        var carbsG: FoodCatalogNutrient
        var fiberG: FoodCatalogNutrient
        var sodiumMg: FoodCatalogNutrient
    }
}

/// 单个营养素值。`value == nil` 时 `flag` 区分「微量(Tr)」与「未测定(-)」，
/// 两者都不等于 0，展示层必须区分处理（不得一律显示 0）。
struct FoodCatalogNutrient: Codable, Equatable, Sendable {
    enum Flag: String, Codable, Sendable {
        case measured
        case estimated
        case trace
        case unmeasured
    }

    var value: Double?
    var flag: Flag

    var isPresent: Bool { value != nil }
}

enum FoodCatalogCategory: String, Codable, CaseIterable, Sendable {
    case staple
    case eggDairySoy
    case meatSeafood
    case vegetableFruit
    case oilSeasoning

    var displayName: String {
        switch self {
        case .staple: return "主食"
        case .eggDairySoy: return "蛋奶豆"
        case .meatSeafood: return "肉鱼虾"
        case .vegetableFruit: return "蔬果"
        case .oilSeasoning: return "油脂调味"
        }
    }
}

enum FoodCatalogPreparationState: String, Codable, Sendable {
    case raw
    case cooked
    case unknown

    var displayName: String {
        switch self {
        case .raw: return "生"
        case .cooked: return "熟"
        case .unknown: return "加工品/未标注"
        }
    }

    /// 目录生熟状态 → 餐次分项的 preparation_state（同一受控枚举）。
    var mealItemState: MealItemRecord.PreparationState {
        switch self {
        case .raw: return .raw
        case .cooked: return .cooked
        case .unknown: return .unknown
        }
    }
}

enum FoodCatalogBasis: String, Codable, Sendable {
    case per100g
    case per100mL

    var displayUnit: String {
        switch self {
        case .per100g: return "每 100 g"
        case .per100mL: return "每 100 mL"
        }
    }
}
