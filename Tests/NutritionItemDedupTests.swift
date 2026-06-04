import XCTest
@testable import HealthManager

/// Covers `EditableNutritionItem.deduped(_:against:)` — the dish-name dedup that keeps
/// overlapping text+photo inputs from double-listing the same food.
final class NutritionItemDedupTests: XCTestCase {

    private func item(_ name: String, grams: Double = 100) -> EditableNutritionItem {
        EditableNutritionItem(from: MealNutritionAnalyzer.Item(
            name: name, grams: grams,
            calories_kcal: 100, protein_g: 5, fat_g: 3, carbs_g: 12
        ))
    }

    func test_dropsNamesAlreadyPresentInExisting() {
        let existing = [item("米饭"), item("宫保鸡丁")]
        let incoming = [item("米饭"), item("炒青菜")]   // 米饭 dup, 炒青菜 new
        let fresh = EditableNutritionItem.deduped(incoming, against: existing)
        XCTAssertEqual(fresh.map(\.name), ["炒青菜"])
    }

    func test_dropsRepeatsWithinIncoming() {
        let incoming = [item("煎蛋"), item("煎蛋"), item("吐司")]
        let fresh = EditableNutritionItem.deduped(incoming, against: [])
        XCTAssertEqual(fresh.map(\.name), ["煎蛋", "吐司"], "second 煎蛋 within the batch is dropped")
    }

    func test_normalizationIgnoresSpacesAndCase() {
        let existing = [item("Egg Sandwich")]
        let incoming = [item("eggsandwich"), item("EGG SANDWICH "), item("培根")]
        let fresh = EditableNutritionItem.deduped(incoming, against: existing)
        XCTAssertEqual(fresh.map(\.name), ["培根"], "case/space variants collapse to the existing one")
    }

    func test_qualifiersKeepDistinctDishes() {
        // Conservative: differing qualifiers are NOT merged.
        let incoming = [item("美式咖啡（中杯）"), item("美式咖啡（大杯）")]
        let fresh = EditableNutritionItem.deduped(incoming, against: [])
        XCTAssertEqual(fresh.count, 2)
    }

    func test_emptyNamesDropped() {
        let incoming = [item(""), item("  "), item("米饭")]
        let fresh = EditableNutritionItem.deduped(incoming, against: [])
        XCTAssertEqual(fresh.map(\.name), ["米饭"])
    }
}
