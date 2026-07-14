import XCTest
@testable import HealthManager

/// Covers `MealItemDraft.deduped(_:against:)` — the dish-name dedup that keeps
/// overlapping text+photo inputs from double-listing the same food.
final class NutritionItemDedupTests: XCTestCase {

    private func item(_ name: String, grams: Double = 100) -> MealItemDraft {
        MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(
                name: name, grams: grams,
                calories_kcal: 100, protein_g: 5, fat_g: 3, carbs_g: 12
            ),
            batchConfidence: nil,
            modelName: nil
        )
    }

    func test_dropsNamesAlreadyPresentInExisting() {
        let existing = [item("米饭"), item("宫保鸡丁")]
        let incoming = [item("米饭"), item("炒青菜")]   // 米饭 dup, 炒青菜 new
        let fresh = MealItemDraft.deduped(incoming, against: existing)
        XCTAssertEqual(fresh.map(\.name), ["炒青菜"])
    }

    func test_dropsRepeatsWithinIncoming() {
        let incoming = [item("煎蛋"), item("煎蛋"), item("吐司")]
        let fresh = MealItemDraft.deduped(incoming, against: [])
        XCTAssertEqual(fresh.map(\.name), ["煎蛋", "吐司"], "second 煎蛋 within the batch is dropped")
    }

    func test_normalizationAlignsWithMealItemIdentityCanonicalRuleAcrossUnicodeWhitespace() {
        let pairs: [(String, String)] = [
            (" Egg Sandwich ", "eggsandwich"),
            ("\nEgg\u{00A0}Sandwich\t", "eggsandwich"),
            ("Egg\u{2003}Sandwich", "eggsandwich"),
            ("Egg\u{3000}Sandwich", "eggsandwich"),
            ("\n\tEgg\u{2001}Sandwich\u{2002}\n", "eggsandwich")
        ]
        for (value, expected) in pairs {
            XCTAssertEqual(MealItemIdentity.canonicalName(value), expected)
            XCTAssertEqual(MealItemDraft.normalizedName(value), expected)
        }
    }

    func test_normalizationFiltersDedupByCanonicalRule() {
        let existing = [item("Egg Sandwich")]
        let incoming = [item("eggsandwich"), item("EGG  SANDWICH"), item("培根")]
        let fresh = MealItemDraft.deduped(incoming, against: existing)
        XCTAssertEqual(fresh.map(\.name), ["培根"], "case and whitespace variants collapse to the existing one")
    }

    func test_qualifiersKeepDistinctDishes() {
        // Conservative: differing qualifiers are NOT merged.
        let incoming = [item("美式咖啡（中杯）"), item("美式咖啡（大杯）")]
        let fresh = MealItemDraft.deduped(incoming, against: [])
        XCTAssertEqual(fresh.count, 2)
    }

    func test_emptyNamesDropped() {
        let incoming = [item(""), item("  "), item("米饭")]
        let fresh = MealItemDraft.deduped(incoming, against: [])
        XCTAssertEqual(fresh.map(\.name), ["米饭"])
    }
}
