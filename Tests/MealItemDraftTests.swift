import XCTest
@testable import HealthManager

final class MealItemDraftTests: XCTestCase {

    func test_aiMapping_keepsUnknownValues_andStoresConfidenceAndModelName() {
        let draft = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(
                name: "番茄炒蛋",
                grams: nil,
                calories_kcal: nil,
                protein_g: nil,
                fat_g: nil,
                carbs_g: nil
            ),
            batchConfidence: "MEDIUM",
            modelName: "  gpt-test-v1  "
        )

        XCTAssertEqual(draft.name, "番茄炒蛋")
        XCTAssertTrue(draft.gramsText.isEmpty)
        XCTAssertEqual(draft.provenanceKind, .aiEstimate)
        XCTAssertEqual(draft.confidence, .medium)
        XCTAssertEqual(draft.provenanceRef, "gpt-test-v1")
        XCTAssertNil(draft.provenanceVersion)
        XCTAssertNil(draft.calories)
        XCTAssertNil(draft.protein)
        XCTAssertNil(draft.fat)
        XCTAssertNil(draft.carbs)
        XCTAssertFalse(draft.isUserEdited)
    }

    func test_aiMapping_keepsProvenanceVersionAndPassesThroughToItemInput() throws {
        let draft = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(
                name: "番茄炒蛋",
                grams: 100,
                calories_kcal: 200,
                protein_g: 4,
                fat_g: 2,
                carbs_g: 10
            ),
            batchConfidence: "low",
            modelName: "model-x",
            provenanceVersion: "v1.2.3"
        )

        let input = try draft.toItemInput()
        XCTAssertEqual(draft.provenanceVersion, "v1.2.3")
        XCTAssertEqual(input.provenanceVersion, "v1.2.3")
    }

    func test_confidenceAndModelNameNormalizeWithoutInventingMetadata() {
        XCTAssertEqual(MealItemDraft.normalizedConfidence("  low "), .low)
        XCTAssertEqual(MealItemDraft.normalizedConfidence("Medium"), .medium)
        XCTAssertEqual(MealItemDraft.normalizedConfidence("HIGH"), .high)
        XCTAssertNil(MealItemDraft.normalizedConfidence("super-high"))
        XCTAssertEqual(MealItemDraft.normalizedModelName("  model-x  "), "model-x")
        XCTAssertNil(MealItemDraft.normalizedModelName("   "))
    }

    func test_manualDraftDoesNotForgeDefaultsAndKeepsManualNotEdited() throws {
        let item = MealItemDraft.manualEmpty()
        let initialInput = try item.toItemInput()

        XCTAssertEqual(item.name, "")
        XCTAssertEqual(item.gramsText, "")
        XCTAssertNil(item.calories)
        XCTAssertNil(item.protein)
        XCTAssertNil(item.fat)
        XCTAssertNil(item.carbs)
        XCTAssertFalse(item.isUserEdited)
        XCTAssertNil(initialInput.grams)
        XCTAssertNil(initialInput.caloriesKcal)
        XCTAssertNil(initialInput.proteinG)
        XCTAssertNil(initialInput.fatG)
        XCTAssertNil(initialInput.carbsG)
        XCTAssertEqual(initialInput.provenanceKind, .manual)

        var edited = item
        edited.name = "鸡腿"
        edited.name = "鸡腿"
        edited.gramsText = "250"
        edited.gramsText = "250"

        XCTAssertNil(edited.calories)
        XCTAssertNil(edited.protein)
        XCTAssertNil(edited.fat)
        XCTAssertNil(edited.carbs)
        XCTAssertFalse(edited.isUserEdited)
    }

    func test_snapshotToDraftToMealStoreInputRetainsMetadataAndNumericPrecision() throws {
        let record = MealItemRecord(
            id: 9,
            mealId: 88,
            sortOrder: 1,
            name: "手抓饼（椒盐版）",
            grams: 123.45,
            preparationState: .cooked,
            caloriesKcal: 321.5,
            proteinG: 12.25,
            fatG: 8.75,
            carbsG: 44.125,
            provenanceKind: .nutritionDatabase,
            provenanceRef: "db:entry-1",
            provenanceVersion: "v3",
            confidence: .high,
            isUserEdited: true,
            createdAt: 1_111,
            updatedAt: 1_222
        )

        let draft = MealItemDraft(record: record)
        let input = try draft.toItemInput()

        XCTAssertEqual(input.name, "手抓饼（椒盐版）")
        XCTAssertEqual(input.grams, 123.45)
        XCTAssertEqual(input.caloriesKcal, 321.5)
        XCTAssertEqual(input.proteinG, 12.25)
        XCTAssertEqual(input.fatG, 8.75)
        XCTAssertEqual(input.carbsG, 44.125)
        XCTAssertEqual(input.preparationState, .cooked)
        XCTAssertEqual(input.provenanceKind, .nutritionDatabase)
        XCTAssertEqual(input.provenanceRef, "db:entry-1")
        XCTAssertEqual(input.provenanceVersion, "v3")
        XCTAssertEqual(input.confidence, .high)
        XCTAssertEqual(input.isUserEdited, true)
        XCTAssertEqual(input.createdAt, 1_111)
    }

    func test_scaleOnlyByEditedGramsAndKeepsNilMetricsAndBaselineWhenNoKnownGrams() {
        let withKnownGrams = MealItemDraft(record: MealItemRecord(
            id: nil,
            mealId: 10,
            sortOrder: 0,
            name: "米饭",
            grams: 100,
            preparationState: .unknown,
            caloriesKcal: 200,
            proteinG: 4,
            fatG: 2,
            carbsG: nil,
            provenanceKind: .aiEstimate,
            provenanceRef: nil,
            provenanceVersion: nil,
            confidence: nil,
            isUserEdited: false,
            createdAt: 100,
            updatedAt: 100
        ))

        var fromKnown = withKnownGrams
        fromKnown.gramsText = "200"
        XCTAssertEqual(fromKnown.calories, 400)
        XCTAssertEqual(fromKnown.protein, 8)
        XCTAssertEqual(fromKnown.fat, 4)
        XCTAssertNil(fromKnown.carbs)

        fromKnown.gramsText = ""
        XCTAssertEqual(fromKnown.calories, 200)
        XCTAssertEqual(fromKnown.protein, 4)
        XCTAssertEqual(fromKnown.fat, 2)
        XCTAssertNil(fromKnown.carbs)

        var withoutBaseline = MealItemDraft(record: MealItemRecord(
            id: nil,
            mealId: 11,
            sortOrder: 0,
            name: "炒青菜",
            grams: nil,
            preparationState: .unknown,
            caloriesKcal: 120,
            proteinG: 6,
            fatG: 2.5,
            carbsG: 10,
            provenanceKind: .manual,
            provenanceRef: nil,
            provenanceVersion: nil,
            confidence: nil,
            isUserEdited: false,
            createdAt: 200,
            updatedAt: 200
        ))

        withoutBaseline.gramsText = "500"
        XCTAssertEqual(withoutBaseline.calories, 120)
        XCTAssertEqual(withoutBaseline.protein, 6)
        XCTAssertEqual(withoutBaseline.fat, 2.5)
        XCTAssertEqual(withoutBaseline.carbs, 10)
    }

    func test_nonManualDraftMarksEditedOnActualChangeAndSticksAfterRevert() {
        var changed = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(name: "Egg Sandwich", grams: 120, calories_kcal: 220, protein_g: 9, fat_g: 12, carbs_g: 8),
            batchConfidence: nil,
            modelName: nil
        )
        XCTAssertFalse(changed.isUserEdited)

        changed.name = "egg sandwich"
        XCTAssertTrue(changed.isUserEdited)

        changed.name = "Egg Sandwich"
        XCTAssertTrue(changed.isUserEdited)

        var spacingChanged = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(name: "米饭", grams: 120, calories_kcal: 200, protein_g: 4, fat_g: 1, carbs_g: 44),
            batchConfidence: nil,
            modelName: nil
        )
        spacingChanged.name = "米饭 "
        XCTAssertTrue(spacingChanged.isUserEdited)

        var gramsChanged = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(name: "番茄鸡蛋", grams: 120, calories_kcal: 220, protein_g: 9, fat_g: 12, carbs_g: 8),
            batchConfidence: nil,
            modelName: nil
        )
        let baselineGramsText = gramsChanged.gramsText

        gramsChanged.gramsText = "240"
        XCTAssertTrue(gramsChanged.isUserEdited)

        gramsChanged.gramsText = baselineGramsText
        XCTAssertTrue(gramsChanged.isUserEdited)

        var noChange = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(name: "西红柿鸡蛋", grams: 120, calories_kcal: 220, protein_g: 9, fat_g: 12, carbs_g: 8),
            batchConfidence: nil,
            modelName: nil
        )
        noChange.name = "西红柿鸡蛋"
        let unchangedGrams = noChange.gramsText
        noChange.gramsText = unchangedGrams
        XCTAssertFalse(noChange.isUserEdited)
    }

    func test_toItemInputValidatesGramsAndAcceptsEmptyAsNil() throws {
        let source = MealItemDraft.fromAiEstimate(
            item: MealNutritionAnalyzer.Item(name: "水果", grams: 100, calories_kcal: 80, protein_g: 1, fat_g: 0, carbs_g: 20),
            batchConfidence: nil,
            modelName: nil
        )

        var invalid = source
        for invalidText in ["abc", "0", "-12", "nan", "inf"] {
            invalid.gramsText = invalidText
            XCTAssertThrowsError(try invalid.toItemInput()) { error in
                guard case .invalidGrams(let raw) = error as? MealItemDraft.ValidationError else {
                    XCTFail("Expected invalidGrams error")
                    return
                }
                XCTAssertEqual(raw, invalidText)
            }
        }

        invalid.gramsText = ""
        let emptyInput = try invalid.toItemInput()
        XCTAssertNil(emptyInput.grams)

        invalid.gramsText = "  250.5  "
        let validInput = try invalid.toItemInput()
        XCTAssertEqual(validInput.grams, 250.5)
    }
}
