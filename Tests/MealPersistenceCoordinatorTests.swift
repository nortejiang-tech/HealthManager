import Foundation
import XCTest
@testable import HealthManager

final class MealPersistenceCoordinatorTests: XCTestCase {

    func test_saveWritesToHealthUsingStoreProjectionAndPersistsSyncIdWhenWritten() async throws {
        let store = makeStore()
        let seed = try await store.save(
            meal: makeMeal(
                mealType: .lunch,
                eatenAt: 1_000,
                photoPath: "kept.jpg,old-removed.jpg",
                createdAt: 10,
                caloriesKcal: 11
            ),
            items: []
        )
        let baseline = MealItemRecord(
            id: nil,
            mealId: 0,
            sortOrder: 0,
            name: "Apple",
            grams: 120,
            preparationState: .raw,
            caloriesKcal: 30,
            proteinG: 3,
            fatG: 4,
            carbsG: 2,
            provenanceKind: .manual,
            provenanceRef: nil,
            provenanceVersion: nil,
            confidence: nil,
            isUserEdited: false,
            createdAt: 10,
            updatedAt: 10
        )
        let draft = MealItemDraft(record: baseline)

        var writerMeals: [MealRecord] = []
        var removedPhotos: [String] = []

        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { meal in
                writerMeals.append(meal)
                let loaded = try! await store.load(id: meal.id!)
                XCTAssertNil(loaded?.meal.hkSyncId)
                XCTAssertEqual(loaded?.meal.photoPaths.contains("old-removed.jpg"), false)
                return .written(syncID: "hk-written")
            },
            removePhotoIfManaged: { removedPhotos.append($0) },
            deleteHealthKitSamples: { _ in }
        )

        var toSave = seed.meal
        toSave.photoPath = "kept.jpg,new-added.jpg"
        let result = try await coordinator.save(
            meal: toSave,
            drafts: [draft],
            originalPhotoPaths: ["kept.jpg", "old-removed.jpg"]
        )

        XCTAssertEqual(removedPhotos, ["old-removed.jpg"])
        XCTAssertEqual(writerMeals.count, 1)
        let projectedMeal = writerMeals[0]
        XCTAssertEqual(projectedMeal.id, result.meal.id)
        XCTAssertEqual(projectedMeal.photoPaths.sorted(), ["kept.jpg", "new-added.jpg"])
        XCTAssertEqual(projectedMeal.caloriesKcal, 30)
        XCTAssertEqual(result.meal.hkSyncId, "hk-written")
        let saved = try await store.load(id: result.meal.id!)
        XCTAssertEqual(saved?.meal.hkSyncId, "hk-written")
    }

    func test_saveLeavesPhotoAndIdStateConsistentWhenHealthKitNotWritten() async throws {
        let store = makeStore()
        let seed = try await store.save(
            meal: makeMeal(
                mealType: .snack,
                eatenAt: 2_000,
                photoPath: "keep.jpg,delete-me.jpg",
                createdAt: 20,
                hkSyncId: "existing-sync"
            ),
            items: []
        )

        var writerCallCount = 0
        var removedPhotos: [String] = []

        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { _ in
                writerCallCount += 1
                return .notWritten
            },
            removePhotoIfManaged: { removedPhotos.append($0) },
            deleteHealthKitSamples: { _ in
                XCTFail("delete should not be called from save")
            }
        )

        var toSave = seed.meal
        toSave.photoPath = "keep.jpg"
        let result = try await coordinator.save(
            meal: toSave,
            drafts: [],
            originalPhotoPaths: ["keep.jpg", "delete-me.jpg"]
        )

        XCTAssertEqual(writerCallCount, 1)
        XCTAssertEqual(removedPhotos, ["delete-me.jpg"])
        XCTAssertEqual(result.meal.hkSyncId, "existing-sync")
        let saved = try await store.load(id: seed.meal.id!)
        XCTAssertEqual(saved?.meal.hkSyncId, "existing-sync")
    }

    func test_saveStoreSaveFailureAvoidsDbAndExternalSideEffects() async throws {
        let store = makeStore()
        let validDraft = MealItemDraft(record: MealItemRecord(
            id: nil,
            mealId: 0,
            sortOrder: 0,
            name: "Apple",
            grams: 120,
            preparationState: .raw,
            caloriesKcal: 1,
            proteinG: nil,
            fatG: nil,
            carbsG: nil,
            provenanceKind: .manual,
            provenanceRef: nil,
            provenanceVersion: nil,
            confidence: nil,
            isUserEdited: false,
            createdAt: 10,
            updatedAt: 10
        ))

        var writerCalled = false
        var removedPhotos: [String] = []
        var deletedSyncIds: [String] = []

        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { _ in
                writerCalled = true
                return .written(syncID: "should-not-write")
            },
            removePhotoIfManaged: { removedPhotos.append($0) },
            deleteHealthKitSamples: { syncId in
                deletedSyncIds.append(syncId)
            }
        )

        do {
            _ = try await coordinator.save(
                meal: MealRecord(
                    id: 9_999_999,
                    mealType: .lunch,
                    eatenAt: 9_000,
                    caloriesKcal: nil,
                    proteinG: nil,
                    fatG: nil,
                    carbsG: nil,
                    photoPath: "persisted.jpg",
                    notes: nil,
                    createdAt: 90,
                    hkSyncId: nil
                ),
                drafts: [validDraft],
                originalPhotoPaths: ["persisted.jpg", "deleted.jpg"]
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MealStoreError, .mealNotFound(9_999_999))
        }

        XCTAssertFalse(writerCalled)
        XCTAssertTrue(removedPhotos.isEmpty)
        XCTAssertTrue(deletedSyncIds.isEmpty)
    }

    func test_saveDraftValidationFailureAvoidsDbAndExternalSideEffects() async {
        let store = makeStore()
        let seed = try! await store.save(
            meal: makeMeal(
                mealType: .breakfast,
                eatenAt: 3_000,
                photoPath: "keep.jpg",
                createdAt: 30
            ),
            items: []
        )
        var writerCalled = false
        var removed: [String] = []
        var draft = MealItemDraft.manualEmpty()
        draft.name = "Invalid"
        draft.gramsText = "oops"

        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { _ in
                writerCalled = true
                return .written(syncID: "should-not-call")
            },
            removePhotoIfManaged: { removed.append($0) },
            deleteHealthKitSamples: { _ in
                XCTFail("healthkit should not be called on validation failure")
            }
        )

        do {
            _ = try await coordinator.save(
                meal: seed.meal,
                drafts: [draft],
                originalPhotoPaths: ["keep.jpg", "deleted.jpg"]
            )
            XCTFail("expected throw")
        } catch {
            // expected
        }

        XCTAssertFalse(writerCalled)
        XCTAssertTrue(removed.isEmpty)
        let loaded = try! await store.load(id: seed.meal.id!)
        let preserved = try! XCTUnwrap(loaded?.meal)
        XCTAssertEqual(preserved.photoPath, "keep.jpg")
    }

    func test_deleteCleansReceiptPhotosAndHealthKitSamplesBeforeCompletion() async throws {
        let store = makeStore()
        let seed = try await store.save(
            meal: makeMeal(
                mealType: .dinner,
                eatenAt: 4_000,
                photoPath: "one.jpg,two.jpg",
                createdAt: 40,
                hkSyncId: "hk-123"
            ),
            items: [
                .init(name: "Seed", caloriesKcal: 1, provenanceKind: .manual)
            ]
        )

        var removedPhotos: [String] = []
        var deletedSyncIds: [String] = []
        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { _ in
                XCTFail("save should not trigger writer")
                return .written(syncID: "unused")
            },
            removePhotoIfManaged: { removedPhotos.append($0) },
            deleteHealthKitSamples: { syncId in
                deletedSyncIds.append(syncId)
            }
        )

        try await coordinator.delete(mealId: seed.meal.id!)
        XCTAssertEqual(Set(removedPhotos), Set(["one.jpg", "two.jpg"]))
        XCTAssertEqual(deletedSyncIds, ["hk-123"])
        let afterDelete = try await store.load(id: seed.meal.id!)
        XCTAssertNil(afterDelete)
    }

    func test_deleteMissingIdSkipsAllExternalSideEffects() async throws {
        let store = makeStore()
        var removedPhotos: [String] = []
        var deletedSyncIds: [String] = []

        let coordinator = MealPersistenceCoordinator(
            mealStore: store,
            writeNutritionToHealth: { _ in
                XCTFail("save should not trigger writer")
                return .written(syncID: "unused")
            },
            removePhotoIfManaged: { removedPhotos.append($0) },
            deleteHealthKitSamples: { syncId in
                deletedSyncIds.append(syncId)
            }
        )

        try await coordinator.delete(mealId: 999_999)

        XCTAssertTrue(removedPhotos.isEmpty)
        XCTAssertTrue(deletedSyncIds.isEmpty)
    }

    private func makeStore() -> MealStore {
        MealStore(databaseManager: DatabaseManager.makeInMemoryForTesting())
    }

    private func makeMeal(
        id: Int64? = nil,
        mealType: MealRecord.MealType,
        eatenAt: Int64,
        photoPath: String? = nil,
        createdAt: Int64,
        hkSyncId: String? = nil,
        caloriesKcal: Double? = nil
    ) -> MealRecord {
        MealRecord(
            id: id,
            mealType: mealType,
            eatenAt: eatenAt,
            caloriesKcal: caloriesKcal,
            proteinG: nil,
            fatG: nil,
            carbsG: nil,
            photoPath: photoPath,
            notes: nil,
            createdAt: createdAt,
            hkSyncId: hkSyncId
        )
    }
}
