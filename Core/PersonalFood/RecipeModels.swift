import Foundation

/// 配方原料：引用官方目录条目并冻结**完整营养快照**（v0.7 起，ADR-005）——
/// 目录更新、资料移除后，旧配方仍能独立还原当时的每 100 g/100 mL 数值、
/// 质量标记与出处，不依赖"当前目录"回读。
/// 克数与「用量状态」分开保存——未知用量不得按 0 处理（ADR-004 §2.4）。
struct RecipeIngredient: Codable, Equatable, Sendable {
    enum AmountStatus: String, Codable, CaseIterable, Sendable {
        /// 已称量。
        case weighed
        /// 用户明确估计的用量（显示“配方估算·比例估计”语义）。
        case estimated
        /// 明确未使用（0 g）。
        case notUsed
        /// 用量未知——贡献按未知处理，不能当 0。
        case unknown
    }

    var catalogEntryId: String
    var catalogVersion: String
    var nameZh: String
    var basis: FoodCatalogBasis
    var preparationState: MealItemRecord.PreparationState
    var grams: Double?
    var amountStatus: AmountStatus
    /// 当时所用资料版本的完整营养快照；nil = 待修复
    /// （旧配方原料且无法用可确认的原版本资料补齐时保留 nil，不冒充）。
    var nutritionSnapshot: IngredientNutritionSnapshot?
    /// 待匹配原料：推测出但资料库中暂无可信官方候选的占位行。
    /// 非 nil 时允许 选择/替换/删除；受影响的营养按未知传播，不得略去。
    var pendingName: String?

    var isPendingMatch: Bool { pendingName != nil }

    var displayName: String {
        isPendingMatch ? (pendingName ?? "待匹配原料") : nameZh
    }
}

/// 原料引用的资料版本快照：随配方版本（进而随备份 v3）持久化，离线可还原。
struct IngredientNutritionSnapshot: Codable, Equatable, Sendable {
    var provider: String
    var providerFoodId: String
    var versionLabel: String
    var basis: FoodCatalogBasis
    var per100: FoodCatalogEntry.Nutrients
    var nameOriginal: String?
    var sourceUrl: String?
    var capturedAt: Int64

    /// 从目录条目形态捕获快照（离线目录条目、个人库版本合成条目共用）。
    static func capture(
        from entry: FoodCatalogEntry,
        versionLabel: String,
        capturedAt: Int64
    ) -> IngredientNutritionSnapshot {
        IngredientNutritionSnapshot(
            provider: entry.source,
            providerFoodId: entry.foodNo,
            versionLabel: versionLabel,
            basis: entry.basis,
            per100: entry.nutrients,
            nameOriginal: entry.nameOriginal,
            sourceUrl: entry.sourceUrl,
            capturedAt: capturedAt
        )
    }
}

/// 配方计算（§5.3 计算规则）：
/// 同状态食材贡献 = 每100g值 × 克重 / 100；成品总营养 = 各项之和；
/// 每100g = 总营养 × 100 / 实际成品重量。
/// - 任一参与原料某营养素未知 → 成品该营养素未知（已知小计不算完整总量）；
/// - 任一原料用量未知 → 全部总量按未知处理（未知用油不得按 0）；
/// - 未使用（notUsed）原料不参与；
/// - 成品重量 0 / 负 / 非有限 → 不产出每 100 g（允许保存待补草稿）。
enum RecipeCalculator {

    struct IngredientInput: Equatable, Sendable {
        /// 目录条目的「每 100 单位」营养值。
        let per100: FoodCatalogEntry.Nutrients
        let grams: Double?
        let status: RecipeIngredient.AmountStatus

        init(entry: FoodCatalogEntry, grams: Double?, status: RecipeIngredient.AmountStatus) {
            self.per100 = entry.nutrients
            self.grams = grams
            self.status = status
        }

        init(per100: FoodCatalogEntry.Nutrients, grams: Double?, status: RecipeIngredient.AmountStatus) {
            self.per100 = per100
            self.grams = grams
            self.status = status
        }
    }

    struct Totals: Equatable, Sendable {
        let caloriesKcal: Double?
        let proteinG: Double?
        let fatG: Double?
        let carbsG: Double?
    }

    struct Output: Equatable, Sendable {
        /// 成品总量；用量未知时各项为 nil。
        let totals: Totals
        /// 任一原料用量未知。
        let isAmountUnknown: Bool
        /// 有原料的某营养素缺失（即便其他营养素完整）。
        let hasMissingNutrient: Bool
        /// 参与计算的原料克重之和（无有效原料时为 0）。
        let inputGrams: Double
        let outputGrams: Double?

        /// 成品每 100 g；成品重量非法或原料用量未知时为 nil（待补）。
        var per100: Totals? {
            guard !isAmountUnknown,
                  let outputGrams,
                  FoodServingCalculator.validGrams(outputGrams) else { return nil }
            func scale(_ value: Double?) -> Double? {
                guard let value else { return nil }
                return value * 100 / outputGrams
            }
            return Totals(
                caloriesKcal: scale(totals.caloriesKcal),
                proteinG: scale(totals.proteinG),
                fatG: scale(totals.fatG),
                carbsG: scale(totals.carbsG)
            )
        }
    }

    static func calculate(ingredients: [IngredientInput], outputGrams: Double?) -> Output {
        var calories: Double = 0
        var protein: Double = 0
        var fat: Double = 0
        var carbs: Double = 0
        var missingCalories = false
        var missingProtein = false
        var missingFat = false
        var missingCarbs = false
        var isAmountUnknown = false
        var inputGrams: Double = 0
        var contributingCount = 0

        for ingredient in ingredients {
            switch ingredient.status {
            case .notUsed:
                continue
            case .unknown:
                isAmountUnknown = true
                continue
            case .weighed, .estimated:
                break
            }

            guard let grams = ingredient.grams, FoodServingCalculator.validGrams(grams) else {
                // 已声明用量但数值非法：同样不能当 0。
                isAmountUnknown = true
                continue
            }

            let factor = grams / 100
            inputGrams += grams
            contributingCount += 1

            func add(_ nutrient: FoodCatalogNutrient, to: inout Double, missing: inout Bool) {
                guard let value = nutrient.value else {
                    missing = true
                    return
                }
                to += value * factor
            }
            add(ingredient.per100.kcal, to: &calories, missing: &missingCalories)
            add(ingredient.per100.proteinG, to: &protein, missing: &missingProtein)
            add(ingredient.per100.fatG, to: &fat, missing: &missingFat)
            add(ingredient.per100.carbsG, to: &carbs, missing: &missingCarbs)
        }

        let hasMissing = missingCalories || missingProtein || missingFat || missingCarbs
        func resolve(_ value: Double, missing: Bool) -> Double? {
            if isAmountUnknown || missing || contributingCount == 0 { return nil }
            return value
        }

        return Output(
            totals: Totals(
                caloriesKcal: resolve(calories, missing: missingCalories),
                proteinG: resolve(protein, missing: missingProtein),
                fatG: resolve(fat, missing: missingFat),
                carbsG: resolve(carbs, missing: missingCarbs)
            ),
            isAmountUnknown: isAmountUnknown,
            hasMissingNutrient: hasMissing || contributingCount == 0,
            inputGrams: inputGrams,
            outputGrams: outputGrams
        )
    }
}
