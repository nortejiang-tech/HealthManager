import XCTest
import UIKit

@testable import HealthManager

final class MealEditorDraftTests: XCTestCase {

    func test_initNewMealDefaultsToReadyManualMode() {
        let fixedClock: Int64 = 1_234_567
        let draft = MealEditorDraft(meal: nil, now: { fixedClock })

        XCTAssertNil(draft.id)
        XCTAssertEqual(draft.loadState, .ready)
        XCTAssertTrue(draft.isManualSummaryMode)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.createdAt, fixedClock)
        XCTAssertTrue(draft.allPhotoPaths.isEmpty)
    }

    func test_initExistingMealStartsLoadingThenReadyAfterApply() {
        let snapshot = makeSnapshot(id: 1)
        let draftWithoutLoad = MealEditorDraft(meal: snapshot.meal)

        XCTAssertEqual(draftWithoutLoad.loadState, .loading)
        XCTAssertFalse(draftWithoutLoad.canSave)

        var loaded = draftWithoutLoad
        loaded.apply(snapshot: snapshot, loadImage: { _ in nil })

        XCTAssertEqual(loaded.loadState, .ready)
        XCTAssertTrue(loaded.canSave)
        XCTAssertFalse(loaded.nutritionItems.isEmpty)
        XCTAssertEqual(loaded.nutritionItems[0].name, "苹果")
        XCTAssertEqual(loaded.nutritionItems.map(\.gramsText), ["100", "40"])
    }

    func test_initExistingMealWithoutIdIsFailedAndCannotSave() {
        let meal = makeMeal(id: nil, notes: "需要手工编辑")
        let draft = MealEditorDraft(meal: meal)

        XCTAssertEqual(draft.loadState, .failed("该餐次缺少 ID，无法编辑已有记录"))
        XCTAssertFalse(draft.canSave)
    }

    func test_applyPreservesParentAndItemMetadataAndPhotoGaps() {
        let snapshot = makeSnapshot(id: 2)
        var draft = MealEditorDraft(meal: snapshot.meal)
        draft.apply(
            snapshot: snapshot,
            loadImage: { path in
                return path == "missing.jpg" ? nil : UIImage()
            }
        )

        XCTAssertEqual(draft.createdAt, 123)
        XCTAssertEqual(draft.hkSyncId, "sync-id")
        XCTAssertEqual(draft.id, 2)
        XCTAssertEqual(draft.mealType, .dinner)
        XCTAssertEqual(draft.eatenAt.timeIntervalSince1970, 12_345, accuracy: 0.001)
        XCTAssertEqual(draft.notes, "父级备注")
        XCTAssertEqual(draft.caloriesText, "10.25")
        XCTAssertEqual(draft.proteinText, "")
        XCTAssertEqual(draft.fatText, "5.0")
        XCTAssertEqual(draft.carbsText, "20.75")
        XCTAssertEqual(draft.allPhotoPaths, ["stored.jpg", "missing.jpg", "stored2.jpg"])
        XCTAssertEqual(draft.photoDrafts.map(\.path), ["stored.jpg", "missing.jpg", "stored2.jpg"])
        XCTAssertNil(draft.photoDrafts[1].image)

        XCTAssertEqual(draft.nutritionItems.count, 2)
        XCTAssertEqual(draft.nutritionItems[0].name, "苹果")
        XCTAssertEqual(draft.nutritionItems[0].gramsText, "100")
        XCTAssertEqual(draft.nutritionItems[0].preparationState, .raw)
        XCTAssertEqual(draft.nutritionItems[0].provenanceKind, .manual)
        XCTAssertNil(draft.nutritionItems[0].provenanceRef)
        XCTAssertNil(draft.nutritionItems[0].provenanceVersion)
        XCTAssertNil(draft.nutritionItems[0].confidence)
        XCTAssertFalse(draft.nutritionItems[0].isUserEdited)
        XCTAssertEqual(draft.nutritionItems[0].createdAt, 123)

        XCTAssertEqual(draft.nutritionItems[1].preparationState, .cooked)
        XCTAssertEqual(draft.nutritionItems[1].provenanceKind, .aiEstimate)
        XCTAssertEqual(draft.nutritionItems[1].provenanceRef, "model")
        XCTAssertEqual(draft.nutritionItems[1].provenanceVersion, "1.0")
        XCTAssertEqual(draft.nutritionItems[1].confidence, .high)
        XCTAssertTrue(draft.nutritionItems[1].isUserEdited)
        XCTAssertEqual(draft.nutritionItems[1].createdAt, 456)
        XCTAssertNil(draft.nutritionItems[1].protein)
        XCTAssertNil(draft.itemTotals?.proteinG)
    }

    func test_makeMealRecordPrefersItemsWhenPresentAndIgnoresParentText() {
        let sourceItem = MealNutritionAnalyzer.Item(
            name: "鸡胸肉",
            grams: 100,
            calories_kcal: 165,
            protein_g: 31,
            fat_g: 3,
            carbs_g: 0
        )
        let fromAi = MealItemDraft.fromAiEstimate(item: sourceItem, batchConfidence: nil, modelName: nil)

        var draft = MealEditorDraft(meal: nil, now: { 777 })
        draft.nutritionItems = [fromAi]
        draft.photoDrafts = [
            MealEditorDraft.MealPhotoDraft(path: "new.jpg", image: UIImage(), isSessionCreated: true)
        ]
        draft.caloriesText = "abc"
        draft.proteinText = "abc"
        draft.fatText = "-1"
        draft.carbsText = "999"
        draft.reconcileTotalsFromItems()

        let meal = try! draft.makeMealRecord()
        XCTAssertEqual(meal.caloriesKcal, 165)
        XCTAssertEqual(meal.proteinG, 31)
        XCTAssertEqual(meal.fatG, 3)
        XCTAssertEqual(meal.carbsG, 0)
        XCTAssertEqual(meal.photoPaths, ["new.jpg"])
        XCTAssertEqual(meal.createdAt, 777)
    }

    func test_makeMealRecordManualFieldsHonorsZeroDecimalAndRejectInvalid() {
        let manual = MealEditorDraft(meal: nil)
        var draft = manual
        draft.nutritionItems = []
        draft.caloriesText = "0"
        draft.proteinText = "0.5"
        draft.fatText = ""
        draft.carbsText = " 3.0 "

        let meal = try! draft.makeMealRecord()
        XCTAssertEqual(meal.caloriesKcal, 0)
        XCTAssertEqual(meal.proteinG, 0.5)
        XCTAssertNil(meal.fatG)
        XCTAssertEqual(meal.carbsG, 3)

        draft.caloriesText = "-1"
        XCTAssertThrowsError(try draft.makeMealRecord())

        draft.caloriesText = "0"
        draft.proteinText = "abc"
        XCTAssertThrowsError(try draft.makeMealRecord())

        draft.proteinText = "0.3"
        draft.fatText = "nan"
        XCTAssertThrowsError(try draft.makeMealRecord())
    }

    func test_removingLastItemPromotesPreviousProjectionToManualSummary() throws {
        let sourceItem = MealNutritionAnalyzer.Item(
            name: "豆腐",
            grams: 100,
            calories_kcal: 80.5,
            protein_g: nil,
            fat_g: 4,
            carbs_g: 0
        )
        var draft = MealEditorDraft(meal: nil)
        draft.nutritionItems = [
            .fromAiEstimate(item: sourceItem, batchConfidence: nil, modelName: nil)
        ]
        draft.reconcileTotalsFromItems()

        draft.nutritionItems.removeAll()
        draft.reconcileTotalsFromItems()

        XCTAssertTrue(draft.isManualSummaryMode)
        XCTAssertNil(draft.itemTotals)
        XCTAssertEqual(draft.caloriesText, "80.5")
        XCTAssertEqual(draft.proteinText, "")
        XCTAssertEqual(draft.fatText, "4.0")
        XCTAssertEqual(draft.carbsText, "0.0")

        let meal = try draft.makeMealRecord()
        XCTAssertEqual(meal.caloriesKcal, 80.5)
        XCTAssertNil(meal.proteinG)
        XCTAssertEqual(meal.fatG, 4)
        XCTAssertEqual(meal.carbsG, 0)
    }

    func test_photoDraftsPreservePathOrderAndSessionRemovedOnly() {
        let nowDraft = MealEditorDraft(meal: makeMeal(id: nil))
        var draft = nowDraft
        draft.photoDrafts = [
            MealEditorDraft.MealPhotoDraft(path: "old.jpg", image: UIImage(), isSessionCreated: false),
            MealEditorDraft.MealPhotoDraft(path: "new-session.jpg", image: UIImage(), isSessionCreated: true),
            MealEditorDraft.MealPhotoDraft(path: "old2.jpg", image: nil, isSessionCreated: false)
        ]
        XCTAssertEqual(draft.allPhotoPaths, ["old.jpg", "new-session.jpg", "old2.jpg"])

        let removed = draft.removePhoto(at: 0)
        XCTAssertEqual(removed?.path, "old.jpg")
        XCTAssertEqual(draft.allPhotoPaths, ["new-session.jpg", "old2.jpg"])

        XCTAssertEqual(draft.sessionCreatedPhotoPaths, ["new-session.jpg"])
    }

    func test_legacyMealWithoutItemsRoundTripsParentNilDecimalsAndIdentity() throws {
        let meal = makeMeal(
            id: 91,
            mealType: .snack,
            eatenAt: 9_876,
            photoPath: "old.jpg,missing.jpg",
            mealSync: "legacy-sync",
            notes: "legacy",
            createdAt: 456,
            calories: 12.5,
            protein: nil,
            fat: 0,
            carbs: 3.25
        )
        var draft = MealEditorDraft(meal: meal)
        draft.apply(snapshot: .init(meal: meal, items: []), loadImage: { _ in nil })

        let roundTrip = try draft.makeMealRecord()

        XCTAssertEqual(roundTrip.id, 91)
        XCTAssertEqual(roundTrip.mealType, .snack)
        XCTAssertEqual(roundTrip.eatenAt, 9_876)
        XCTAssertEqual(roundTrip.caloriesKcal, 12.5)
        XCTAssertNil(roundTrip.proteinG)
        XCTAssertEqual(roundTrip.fatG, 0)
        XCTAssertEqual(roundTrip.carbsG, 3.25)
        XCTAssertEqual(roundTrip.photoPaths, ["old.jpg", "missing.jpg"])
        XCTAssertEqual(roundTrip.notes, "legacy")
        XCTAssertEqual(roundTrip.createdAt, 456)
        XCTAssertEqual(roundTrip.hkSyncId, "legacy-sync")
    }

    func test_userFacingSaveErrorsAreChineseAndFieldSpecific() {
        XCTAssertEqual(
            MealEditorDraft.userFacingSaveError(MealItemDraft.ValidationError.invalidGrams("abc")),
            "菜品克数输入无效：abc"
        )
        XCTAssertEqual(
            MealEditorDraft.userFacingSaveError(MealStoreError.blankItemName(index: 1)),
            "第 2 个菜品名称不能为空"
        )
        XCTAssertEqual(
            MealEditorDraft.userFacingSaveError(
                MealEditorDraft.ValidationError.invalidParentValue(field: "热量", raw: "nan")
            ),
            "热量输入无效：nan"
        )
    }

    private func makeMeal(
        id: Int64?,
        mealType: MealRecord.MealType = .lunch,
        eatenAt: Int64 = 1_000,
        photoPath: String = "stored.jpg",
        mealSync: String? = "sync-id",
        notes: String? = nil,
        createdAt: Int64 = 123,
        calories: Double? = 10,
        protein: Double? = 2,
        fat: Double? = 5,
        carbs: Double? = 20
    ) -> MealRecord {
        MealRecord(
            id: id,
            mealType: mealType,
            eatenAt: eatenAt,
            caloriesKcal: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            photoPath: photoPath,
            notes: notes,
            createdAt: createdAt,
            hkSyncId: mealSync
        )
    }

    private func makeSnapshot(id: Int64) -> MealStore.Snapshot {
        let meal = makeMeal(
            id: id,
            mealType: .dinner,
            eatenAt: 12_345,
            photoPath: "stored.jpg,missing.jpg,stored2.jpg",
            notes: "父级备注",
            calories: 10.25,
            protein: nil,
            fat: 5,
            carbs: 20.75
        )
        let items = [
            MealItemRecord(
                id: 10,
                mealId: id,
                sortOrder: 0,
                name: "苹果",
                grams: 100,
                preparationState: .raw,
                caloriesKcal: 52,
                proteinG: 0.5,
                fatG: 5,
                carbsG: 14,
                provenanceKind: .manual,
                provenanceRef: nil,
                provenanceVersion: nil,
                confidence: nil,
                isUserEdited: false,
                createdAt: 123,
                updatedAt: 123
            ),
            MealItemRecord(
                id: 11,
                mealId: id,
                sortOrder: 1,
                name: "鸡蛋",
                grams: 40,
                preparationState: .cooked,
                caloriesKcal: 12,
                proteinG: nil,
                fatG: 0.5,
                carbsG: 0.3,
                provenanceKind: .aiEstimate,
                provenanceRef: "model",
                provenanceVersion: "1.0",
                confidence: .high,
                isUserEdited: true,
                createdAt: 456,
                updatedAt: 456
            )
        ]
        return MealStore.Snapshot(meal: meal, items: items)
    }
}
