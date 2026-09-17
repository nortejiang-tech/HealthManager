import XCTest
@testable import HealthManager

/// 配方计算合同（§5.3 / 验收 A07/A08）：分母、缺失传播、未知用量、油。
final class RecipeCalculatorTests: XCTestCase {

    private func nutrient(_ value: Double?) -> FoodCatalogNutrient {
        FoodCatalogNutrient(value: value, flag: value == nil ? .unmeasured : .measured)
    }

    private func nutrients(kcal: Double?, p: Double?, f: Double?, c: Double?) -> FoodCatalogEntry.Nutrients {
        FoodCatalogEntry.Nutrients(
            kcal: nutrient(kcal),
            proteinG: nutrient(p),
            fatG: nutrient(f),
            carbsG: nutrient(c),
            fiberG: nutrient(nil),
            sodiumMg: nutrient(nil)
        )
    }

    private func ingredient(
        kcal: Double?, p: Double?, f: Double?, c: Double?,
        grams: Double?, status: RecipeIngredient.AmountStatus
    ) -> RecipeCalculator.IngredientInput {
        RecipeCalculator.IngredientInput(
            per100: nutrients(kcal: kcal, p: p, f: f, c: c),
            grams: grams,
            status: status
        )
    }

    // MARK: 分母（A07）

    func test_outputWeightChangeChangesPer100g_butNotTotals() throws {
        let egg = ingredient(kcal: 134, p: 12.5, f: 10.4, c: 0.3, grams: 150, status: .weighed)
        let milk = ingredient(kcal: 43, p: 3.6, f: 2.8, c: 2.3, grams: 240, status: .weighed)

        // 与方案 §4.1 复算示例一致：150g 煮蛋 + 240g 豆乳。
        let at390 = RecipeCalculator.calculate(ingredients: [egg, milk], outputGrams: 390)
        XCTAssertEqual(at390.totals.caloriesKcal ?? 0, 304.2, accuracy: 0.001)
        XCTAssertEqual(at390.totals.proteinG ?? 0, 27.39, accuracy: 0.001)
        XCTAssertEqual(at390.totals.fatG ?? 0, 22.32, accuracy: 0.001)
        XCTAssertEqual(at390.totals.carbsG ?? 0, 5.97, accuracy: 0.001)

        let per100 = try XCTUnwrap(at390.per100)
        XCTAssertEqual(per100.caloriesKcal ?? 0, 78.0, accuracy: 0.01)
        XCTAssertEqual(per100.proteinG ?? 0, 7.023, accuracy: 0.001)
        XCTAssertEqual(per100.fatG ?? 0, 5.723, accuracy: 0.001)
        XCTAssertEqual(per100.carbsG ?? 0, 1.531, accuracy: 0.001)

        // 相同总营养、成品变 400g → 每100g 变化；总量不变。
        let at400 = RecipeCalculator.calculate(ingredients: [egg, milk], outputGrams: 400)
        XCTAssertEqual(at400.totals.caloriesKcal ?? 0, 304.2, accuracy: 0.001)
        XCTAssertEqual(at400.per100?.caloriesKcal ?? 0, 304.2 * 100 / 400, accuracy: 0.001)
    }

    // MARK: 缺失传播（A08）

    func test_missingNutrientInAnyIngredient_makesThatTotalUnknown_butOthersComplete() {
        let known = ingredient(kcal: 100, p: 10, f: 5, c: 10, grams: 100, status: .weighed)
        let missingProtein = ingredient(kcal: 50, p: nil, f: 1, c: 5, grams: 200, status: .weighed)

        let result = RecipeCalculator.calculate(ingredients: [known, missingProtein], outputGrams: 300)
        XCTAssertNotNil(result.totals.caloriesKcal)
        XCTAssertNil(result.totals.proteinG, "任一原料蛋白未知 → 成品蛋白未知")
        XCTAssertNotNil(result.totals.fatG)
        XCTAssertNotNil(result.totals.carbsG)
        XCTAssertTrue(result.hasMissingNutrient)
        XCTAssertFalse(result.isAmountUnknown)
    }

    // MARK: 未知用量不得按 0

    func test_unknownAmountIngredient_makesAllTotalsUnknown() {
        let egg = ingredient(kcal: 134, p: 12.5, f: 10.4, c: 0.3, grams: 150, status: .weighed)
        let unknownOil = ingredient(kcal: 887, p: 0, f: 100, c: 0, grams: nil, status: .unknown)

        let result = RecipeCalculator.calculate(ingredients: [egg, unknownOil], outputGrams: 200)
        XCTAssertNil(result.totals.caloriesKcal)
        XCTAssertNil(result.totals.fatG, "未知用油不能按 0 处理")
        XCTAssertNil(result.per100)
        XCTAssertTrue(result.isAmountUnknown)
    }

    func test_invalidGramsWithDeclaredAmount_treatedAsUnknown() {
        let badGrams = ingredient(kcal: 100, p: 1, f: 1, c: 1, grams: -5, status: .weighed)
        let result = RecipeCalculator.calculate(ingredients: [badGrams], outputGrams: 100)
        XCTAssertNil(result.totals.caloriesKcal)
        XCTAssertTrue(result.isAmountUnknown)
    }

    // MARK: 未使用（0 g）与已含油熟食条目不重复加油

    func test_notUsedIngredientIsExcluded_andWeighedOilCounts() {
        let chicken = ingredient(kcal: 177, p: 38.8, f: 3.3, c: 0.1, grams: 100, status: .weighed)
        let oil = ingredient(kcal: 887, p: 0, f: 100, c: 0, grams: 10, status: .weighed)
        let noOil = ingredient(kcal: 887, p: 0, f: 100, c: 0, grams: nil, status: .notUsed)

        let withOil = RecipeCalculator.calculate(ingredients: [chicken, oil], outputGrams: 110)
        XCTAssertEqual(withOil.totals.caloriesKcal ?? 0, 177 + 88.7, accuracy: 0.001)

        // 已使用含油成品条目时不重复加同一份油（notUsed 不参与）。
        let withoutExtraOil = RecipeCalculator.calculate(ingredients: [chicken, noOil], outputGrams: 100)
        XCTAssertEqual(withoutExtraOil.totals.caloriesKcal ?? 0, 177, accuracy: 0.001)
    }

    // MARK: 成品重量（A08）

    func test_missingOrInvalidOutputWeight_suppressesPer100g_only() {
        let egg = ingredient(kcal: 134, p: 12.5, f: 10.4, c: 0.3, grams: 150, status: .weighed)

        let pending = RecipeCalculator.calculate(ingredients: [egg], outputGrams: nil)
        XCTAssertNotNil(pending.totals.caloriesKcal, "缺成品重允许总量；只抑制每100g")
        XCTAssertNil(pending.per100)

        for bad in [0.0, -10.0, Double.nan, Double.infinity] {
            let result = RecipeCalculator.calculate(ingredients: [egg], outputGrams: bad)
            XCTAssertNil(result.per100, "outputGrams=\(bad) 必须拒绝每100g")
        }
    }

    func test_emptyContributingIngredients_yieldsUnknownTotals() {
        let result = RecipeCalculator.calculate(ingredients: [], outputGrams: 100)
        XCTAssertNil(result.totals.caloriesKcal)
        XCTAssertTrue(result.hasMissingNutrient)
    }
}
