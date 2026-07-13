import Foundation
import XCTest
import GRDB
@testable import HealthManager

final class MealStoreTests: XCTestCase {

    func test_saveNewMealWithoutItems_preservesProvidedTotalsAndSupportsRoundTrip() async throws {
        let store = makeStore()

        let meal = makeMeal(
            mealType: .breakfast,
            eatenAt: 10,
            caloriesKcal: 600,
            proteinG: 40,
            fatG: 20,
            carbsG: 80,
            photoPath: "photo.png",
            notes: "notes",
            createdAt: 100,
            hkSyncId: "hk-1"
        )
        let saved = try await store.save(meal: meal, items: [])

        XCTAssertNotNil(saved.meal.id)
        XCTAssertEqual(saved.items, [])

        let loaded = try await store.load(id: saved.meal.id!)
        let loadedUnwrapped = try XCTUnwrap(loaded)
        XCTAssertEqual(loadedUnwrapped.meal, saved.meal)
        XCTAssertEqual(loadedUnwrapped.items, [])
        XCTAssertEqual(loadedUnwrapped.meal.caloriesKcal, 600)
        XCTAssertEqual(loadedUnwrapped.meal.proteinG, 40)
        XCTAssertEqual(loadedUnwrapped.meal.fatG, 20)
        XCTAssertEqual(loadedUnwrapped.meal.carbsG, 80)
        XCTAssertEqual(loadedUnwrapped.meal.photoPath, "photo.png")
        XCTAssertEqual(loadedUnwrapped.meal.notes, "notes")
        XCTAssertEqual(loadedUnwrapped.meal.hkSyncId, "hk-1")
        XCTAssertEqual(loadedUnwrapped.meal.createdAt, 100)
    }

    func test_saveWithItemsProjectsByIndexAndPreservesClockSampleOnce() async throws {
        let fixedClock = ThreadSafeClock(reading: 2_000)
        let store = makeStore(now: { fixedClock.read() })

        let meal = makeMeal(eatenAt: 20, createdAt: 10)
        let saved = try await store.save(
            meal: meal,
            items: [
                .init(
                    name: "  Egg ",
                    grams: 50,
                    preparationState: .raw,
                    caloriesKcal: 70,
                    proteinG: 6,
                    fatG: 3,
                    carbsG: 1,
                    provenanceKind: .manual,
                    isUserEdited: true
                ),
                .init(
                    name: "Broccoli",
                    grams: 80,
                    preparationState: .cooked,
                    caloriesKcal: 30,
                    proteinG: 2,
                    fatG: 1,
                    carbsG: 12,
                    provenanceKind: .aiEstimate,
                    confidence: .low
                )
            ]
        )

        XCTAssertEqual(fixedClock.readCount, 1)
        XCTAssertEqual(saved.items.map(\.sortOrder), [0, 1])
        XCTAssertEqual(saved.items.map(\.name), ["Egg", "Broccoli"])
        let savedMealId = try XCTUnwrap(saved.meal.id)
        XCTAssertTrue(saved.items.allSatisfy { $0.id != nil && $0.mealId == savedMealId })
        XCTAssertEqual(saved.meal.caloriesKcal, 100)
        XCTAssertEqual(saved.meal.proteinG, 8)
        XCTAssertEqual(saved.meal.fatG, 4)
        XCTAssertEqual(saved.meal.carbsG, 13)
        XCTAssertEqual(saved.items.allSatisfy { $0.createdAt == 2_000 }, true)
        XCTAssertEqual(saved.items.allSatisfy { $0.updatedAt == 2_000 }, true)
    }

    func test_saveItemsWithUnknownMetricOnlyNilThatMetric() async throws {
        let store = makeStore()

        let meal = makeMeal(eatenAt: 30, createdAt: 11)
        let saved = try await store.save(
            meal: meal,
            items: [
                .init(
                    name: "Item A",
                    caloriesKcal: 100,
                    proteinG: 10,
                    fatG: 2,
                    carbsG: 25,
                    provenanceKind: .manual
                ),
                .init(
                    name: "Item B",
                    caloriesKcal: 200,
                    proteinG: nil,
                    fatG: 3,
                    carbsG: 15,
                    provenanceKind: .manual
                ),
            ]
        )

        XCTAssertEqual(saved.meal.caloriesKcal, 300)
        XCTAssertNil(saved.meal.proteinG)
        XCTAssertEqual(saved.meal.fatG, 5)
        XCTAssertEqual(saved.meal.carbsG, 40)
    }

    func test_updateKeepsMealIdAndPreservesHistoricalCreatedAtForInputItems() async throws {
        let store = makeStore(now: { 500 })
        let seed = try await store.save(
            meal: makeMeal(eatenAt: 40, createdAt: 1),
            items: [.init(name: "Seed", caloriesKcal: 100, provenanceKind: .manual, createdAt: 100)]
        )

        var updatedMeal = seed.meal
        updatedMeal.eatenAt = 42

        let edited = try await store.save(
            meal: updatedMeal,
            items: [
                .init(
                    name: "Updated A",
                    caloriesKcal: 10,
                    proteinG: 1,
                    fatG: 2,
                    carbsG: 3,
                    provenanceKind: .manual,
                    createdAt: 700
                ),
                .init(
                    name: "Updated B",
                    caloriesKcal: 20,
                    proteinG: 2,
                    fatG: 4,
                    carbsG: 6,
                    provenanceKind: .manual
                )
            ]
        )

        XCTAssertEqual(edited.meal.id, seed.meal.id)
        XCTAssertEqual(edited.meal.eatenAt, 42)
        XCTAssertEqual(edited.items.count, 2)
        XCTAssertEqual(edited.items[0].createdAt, 700)
        XCTAssertEqual(edited.items[1].createdAt, 500)
        XCTAssertEqual(edited.meal.caloriesKcal, 30)
        XCTAssertEqual(edited.meal.proteinG, 3)
        XCTAssertEqual(edited.meal.fatG, 6)
        XCTAssertEqual(edited.meal.carbsG, 9)
        XCTAssertTrue(edited.items.allSatisfy { $0.id != nil })
    }

    func test_updateReplacesChildrenInSingleTransaction_andRollsBackOnInvalidChild() async throws {
        let store = makeStore(now: { 600 })

        let seed = try await store.save(
            meal: makeMeal(eatenAt: 50, createdAt: 1),
            items: [.init(name: "Seed", caloriesKcal: 100, proteinG: 2, fatG: 3, carbsG: 4, provenanceKind: .manual)]
        )
        let loadedBefore = try await store.load(id: seed.meal.id!)
        let snapshotBefore = try XCTUnwrap(loadedBefore)
        XCTAssertEqual(snapshotBefore.meal.caloriesKcal, 100)
        XCTAssertEqual(snapshotBefore.items.map(\.name), ["Seed"])

        var updated = seed.meal
        updated.eatenAt = 55

        do {
            _ = try await store.save(
                meal: updated,
                items: [
                    .init(name: "Bad", grams: 0, provenanceKind: .manual),
                    .init(name: "Will Not Persist", caloriesKcal: 10, provenanceKind: .manual),
                ]
            )
            XCTFail("expected throw")
        } catch {
            // expected
        }

        let loadedAfterFailure = try await store.load(id: seed.meal.id!)
        let snapshotReload = try XCTUnwrap(loadedAfterFailure)
        XCTAssertEqual(snapshotReload, snapshotBefore)
    }

    func test_updateUnknownMealIdFailsExplicitly() async {
        let store = makeStore()
        do {
            _ = try await store.save(meal: makeMeal(id: 999_999, eatenAt: 60, createdAt: 1), items: [])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MealStoreError, .mealNotFound(999_999))
        }
    }

    func test_saveRejectsBlankItemNameWithIndex() async {
        let store = makeStore()
        let meal = makeMeal(eatenAt: 70, createdAt: 1)

        do {
            _ = try await store.save(
                meal: meal,
                items: [
                    .init(name: "Valid", caloriesKcal: 10, provenanceKind: .manual),
                    .init(name: "   ", caloriesKcal: 10, provenanceKind: .manual),
                    .init(name: "Other", caloriesKcal: 20, provenanceKind: .manual)
                ]
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MealStoreError, .blankItemName(index: 1))
        }
    }

    func test_deleteReturnsSnapshotAndRemovesMealWithItems() async throws {
        let store = makeStore()
        let seed = try await store.save(
            meal: makeMeal(eatenAt: 80, createdAt: 1),
            items: [
                .init(name: "Item A", caloriesKcal: 1, provenanceKind: .manual),
                .init(name: "Item B", caloriesKcal: 2, provenanceKind: .manual)
            ]
        )

        let deleted = try await store.delete(id: seed.meal.id!)
        let deletedUnwrapped = try XCTUnwrap(deleted)
        XCTAssertEqual(deletedUnwrapped.meal, seed.meal)
        XCTAssertEqual(deletedUnwrapped.items.map(\.name), ["Item A", "Item B"])
        let loadedAfterDelete = try await store.load(id: seed.meal.id!)
        XCTAssertNil(loadedAfterDelete)

        let deletedAgain = try await store.delete(id: seed.meal.id!)
        XCTAssertNil(deletedAgain)
    }

    private func makeStore(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) -> MealStore {
        MealStore(databaseManager: DatabaseManager.makeInMemoryForTesting(), now: now)
    }

    final class ThreadSafeClock: @unchecked Sendable {
        private let lock = NSLock()
        private let reading: Int64
        private var reads = 0

        init(reading: Int64) {
            self.reading = reading
        }

        func read() -> Int64 {
            lock.lock()
            reads += 1
            let value = reading
            lock.unlock()
            return value
        }

        var readCount: Int {
            lock.lock()
            let value = reads
            lock.unlock()
            return value
        }
    }

    private func makeMeal(
        id: Int64? = nil,
        mealType: MealRecord.MealType = .lunch,
        eatenAt: Int64,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        fatG: Double? = nil,
        carbsG: Double? = nil,
        photoPath: String? = nil,
        notes: String? = nil,
        createdAt: Int64,
        hkSyncId: String? = nil
    ) -> MealRecord {
        MealRecord(
            id: id,
            mealType: mealType,
            eatenAt: eatenAt,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            photoPath: photoPath,
            notes: notes,
            createdAt: createdAt,
            hkSyncId: hkSyncId
        )
    }
}
