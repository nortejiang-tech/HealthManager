import Foundation
import GRDB
import XCTest
@testable import HealthManager

final class MealReuseTests: XCTestCase {
    func test_recentSnapshotsSortedAndLimitedAndIncludesLegacyMeals() async throws {
        let store = makeStore()

        let meal1 = try await store.save(
            meal: makeMeal(eatenAt: 1_000, createdAt: 1),
            items: [
                .init(name: "A", caloriesKcal: 10, proteinG: 2, fatG: 1, carbsG: 4, provenanceKind: .manual),
                .init(name: "B", caloriesKcal: 20, proteinG: 3, fatG: 2, carbsG: 6, provenanceKind: .manual)
            ]
        )

        let meal2 = try await store.save(
            meal: makeMeal(eatenAt: 1_000, createdAt: 2),
            items: [
                .init(name: "C", caloriesKcal: 30, proteinG: 4, fatG: 3, carbsG: 7, provenanceKind: .manual)
            ]
        )

        let meal3 = try await store.save(
            meal: makeMeal(eatenAt: 1_000, createdAt: 3),
            items: []
        )

        _ = meal3
        _ = meal2

        let meal4 = try await store.save(
            meal: makeMeal(eatenAt: 900, createdAt: 4),
            items: []
        )

        let snapshots = try await store.recentSnapshots(limit: 3, excludingMealId: meal3.meal.id)

        XCTAssertEqual(
            snapshots.map(\.meal.id),
            [meal2.meal.id, meal1.meal.id, meal4.meal.id]
        )
        XCTAssertEqual(snapshots[0].items.map(\.sortOrder), [0])
        XCTAssertEqual(snapshots[0].items.map(\.name), ["C"])
        XCTAssertEqual(snapshots[1].items.map(\.sortOrder), [0, 1])
        XCTAssertEqual(snapshots[1].items.map(\.name), ["A", "B"])
        XCTAssertEqual(snapshots[2].items, [])

        let limitedSnapshots = try await store.recentSnapshots(limit: 2, excludingMealId: nil)
        XCTAssertEqual(limitedSnapshots.count, 2)

        let emptySnapshotsA = try await store.recentSnapshots(limit: 0, excludingMealId: nil)
        XCTAssertEqual(emptySnapshotsA, [])
        let emptySnapshotsB = try await store.recentSnapshots(limit: -10, excludingMealId: nil)
        XCTAssertEqual(emptySnapshotsB, [])
    }

    func test_recentSnapshotsCapsAtFiftyAndExcludesAfterLimit() async throws {
        let store = makeStore()
        var saved: [MealStore.Snapshot] = []

        for index in 1...55 {
            let snapshot = try await store.save(
                meal: makeMeal(
                    mealType: .lunch,
                    eatenAt: Int64(index),
                    caloriesKcal: nil,
                    proteinG: nil,
                    fatG: nil,
                    carbsG: nil,
                    createdAt: Int64(index)
                ),
                items: []
            )
            saved.append(snapshot)
        }

        let excluded = try XCTUnwrap(saved.last?.meal.id)
        let cappedSnapshots = try await store.recentSnapshots(limit: 100, excludingMealId: excluded)

        XCTAssertEqual(cappedSnapshots.count, 50)
        XCTAssertEqual(cappedSnapshots.first?.meal.id, saved[saved.count - 2].meal.id)
        XCTAssertEqual(cappedSnapshots.last?.meal.id, saved[4].meal.id)
        XCTAssertTrue(cappedSnapshots.allSatisfy { $0.items.isEmpty })
        XCTAssertFalse(cappedSnapshots.map(\.meal.id).contains(excluded))
    }

    func test_commonGramSuggestionsAggregatesByExactGramsAndSortsByFrequencyRecentAndGrams() async throws {
        let store = makeStore()
        let _ = try await store.save(
            meal: makeMeal(eatenAt: 10, createdAt: 1),
            items: [
                .init(
                    name: "Egg Sandwich",
                    grams: 100,
                    preparationState: .raw,
                    caloriesKcal: 30,
                    proteinG: 1,
                    fatG: 1,
                    carbsG: 2,
                    provenanceKind: .manual
                )
            ]
        )
        let _ = try await store.save(
            meal: makeMeal(eatenAt: 20, createdAt: 2),
            items: [
                .init(
                    name: "egg\u{2003}sandwich",
                    grams: 100,
                    preparationState: .raw,
                    caloriesKcal: 35,
                    proteinG: 2,
                    fatG: 2,
                    carbsG: 3,
                    provenanceKind: .manual
                )
            ]
        )
        let _ = try await store.save(
            meal: makeMeal(eatenAt: 30, createdAt: 3),
            items: [
                .init(
                    name: "EGG SANDWICH",
                    grams: 120,
                    preparationState: .raw,
                    caloriesKcal: 40,
                    proteinG: 3,
                    fatG: 3,
                    carbsG: 4,
                    provenanceKind: .manual
                )
            ]
        )
        _ = try await store.save(
            meal: makeMeal(eatenAt: 40, createdAt: 4),
            items: [
                .init(
                    name: "Egg Sandwich",
                    grams: 100,
                    preparationState: .cooked,
                    caloriesKcal: 50,
                    proteinG: 4,
                    fatG: 4,
                    carbsG: 5,
                    provenanceKind: .manual
                )
            ]
        )
        _ = try await store.save(
            meal: makeMeal(eatenAt: 50, createdAt: 5),
            items: [
                .init(
                    name: "Egg Sandwich",
                    grams: nil,
                    preparationState: .raw,
                    caloriesKcal: 70,
                    proteinG: 6,
                    fatG: 6,
                    carbsG: 7,
                    provenanceKind: .manual
                )
            ]
        )
        _ = try await store.save(
            meal: makeMeal(eatenAt: 25, createdAt: 6),
            items: [
                .init(
                    name: "EGG SANDWICH",
                    grams: 80,
                    preparationState: .unknown,
                    caloriesKcal: 60,
                    proteinG: 2,
                    fatG: 2,
                    carbsG: 6,
                    provenanceKind: .manual
                )
            ]
        )

        let allPreparation = try await store.commonGramSuggestions(
            forName: " egg sandwich ",
            preparationState: nil,
            limit: 10
        )

        let expectedAll = [
            MealStore.CommonGramSuggestion(grams: 100, useCount: 3, lastUsedAt: 40),
            MealStore.CommonGramSuggestion(grams: 120, useCount: 1, lastUsedAt: 30)
        ]
        XCTAssertEqual(Array(allPreparation.prefix(2)), expectedAll)

        let rawOnly = try await store.commonGramSuggestions(
            forName: "EggSandwich",
            preparationState: .raw,
            limit: 10
        )
        XCTAssertEqual(rawOnly.map { $0.grams }, [100, 120])
        XCTAssertEqual(rawOnly.map { $0.useCount }, [2, 1])

        let allStates = try await store.commonGramSuggestions(
            forName: "Egg Sandwich",
            preparationState: nil,
            limit: 10
        )
        XCTAssertEqual(allStates.count, 3)
        XCTAssertEqual(allStates.map { $0.grams }, [100, 120, 80])
    }

    func test_commonGramSuggestionsCapsAtTen() async throws {
        let store = makeStore()
        for i in 1...12 {
            _ = try await store.save(
                meal: makeMeal(eatenAt: Int64(i), createdAt: Int64(i)),
                items: [
                    .init(
                        name: "SameName",
                        grams: Double(i),
                        preparationState: .raw,
                        caloriesKcal: Double(i),
                        provenanceKind: .manual
                    )
                ]
            )
        }

        let cappedSuggestions = try await store.commonGramSuggestions(
            forName: "SameName",
            preparationState: .raw,
            limit: 20
        )

        XCTAssertEqual(cappedSuggestions.count, 10)
        XCTAssertEqual(cappedSuggestions.first?.grams, 12)
        XCTAssertEqual(cappedSuggestions.last?.grams, 3)
    }

    func test_commonGramSuggestionsTiesSortByGramsAscending() async throws {
        let store = makeStore()
        _ = try await store.save(
            meal: makeMeal(eatenAt: 10, createdAt: 1),
            items: [
                .init(
                    name: "TieName",
                    grams: 120,
                    preparationState: .raw,
                    provenanceKind: .manual
                )
            ]
        )
        _ = try await store.save(
            meal: makeMeal(eatenAt: 10, createdAt: 2),
            items: [
                .init(
                    name: "TieName",
                    grams: 90,
                    preparationState: .raw,
                    provenanceKind: .manual
                )
            ]
        )
        _ = try await store.save(
            meal: makeMeal(eatenAt: 10, createdAt: 3),
            items: [
                .init(
                    name: "TieName",
                    grams: 100,
                    preparationState: .raw,
                    provenanceKind: .manual
                )
            ]
        )

        let suggestions = try await store.commonGramSuggestions(
            forName: "TieName",
            preparationState: .raw,
            limit: 10
        )
        XCTAssertEqual(suggestions.map { $0.grams }, [90, 100, 120])
        XCTAssertEqual(suggestions.allSatisfy { $0.useCount == 1 }, true)
        XCTAssertEqual(suggestions.map { $0.lastUsedAt }, [10, 10, 10])
    }

    func test_commonGramSuggestions_handlesInvalidNameAndLimit() async throws {
        let store = makeStore()
        _ = try await store.save(
            meal: makeMeal(eatenAt: 1, createdAt: 1),
            items: [.init(name: "SameName", grams: 100, provenanceKind: .manual)]
        )

        let invalidNameSuggestions = try await store.commonGramSuggestions(forName: "", preparationState: nil, limit: 10)
        XCTAssertEqual(invalidNameSuggestions, [])
        let zeroLimitSuggestions = try await store.commonGramSuggestions(forName: "SameName", preparationState: nil, limit: 0)
        XCTAssertEqual(zeroLimitSuggestions, [])
    }

    func test_reuseQueriesAndCopyDraftDoNotMutatePersistedMeals() async throws {
        let databaseManager = DatabaseManager.makeInMemoryForTesting()
        let store = MealStore(databaseManager: databaseManager, now: { 4_444 })
        let saved = try await store.save(
            meal: makeMeal(
                mealType: .lunch,
                eatenAt: 100,
                caloriesKcal: 999,
                proteinG: 999,
                fatG: 999,
                carbsG: 999,
                photoPath: "source-photo.jpg",
                notes: "source-notes",
                createdAt: 100
            ),
            items: [
                .init(
                    name: "Source Item",
                    grams: 125,
                    preparationState: .cooked,
                    caloriesKcal: 250,
                    proteinG: 20,
                    fatG: 10,
                    carbsG: 25,
                    provenanceKind: .manual
                )
            ]
        )
        let sourceId = try XCTUnwrap(saved.meal.id)
        _ = try await store.saveSyncId(mealId: sourceId, syncId: "source-sync-id")
        _ = try await store.save(
            meal: makeMeal(mealType: .dinner, eatenAt: 200, createdAt: 200),
            items: []
        )

        let loadedBefore = try await store.load(id: sourceId)
        let beforeSnapshot = try XCTUnwrap(loadedBefore)
        let beforeCount = try databaseManager.read { db in
            try MealRecord.fetchCount(db)
        }

        _ = try await store.recentSnapshots(limit: 50, excludingMealId: nil)
        _ = try await store.commonGramSuggestions(
            forName: "Source Item",
            preparationState: .cooked,
            limit: 10
        )
        let draft = try store.makeCopyDraft(
            from: beforeSnapshot,
            selection: .wholeMeal,
            targetMealType: .breakfast,
            eatenAt: 300
        )

        let afterCount = try databaseManager.read { db in
            try MealRecord.fetchCount(db)
        }
        let loadedAfter = try await store.load(id: sourceId)
        let afterSnapshot = try XCTUnwrap(loadedAfter)

        XCTAssertEqual(afterCount, beforeCount)
        XCTAssertEqual(afterSnapshot, beforeSnapshot)
        XCTAssertEqual(afterSnapshot.meal.hkSyncId, "source-sync-id")
        XCTAssertNil(draft.meal.id)
        XCTAssertNil(draft.meal.hkSyncId)
    }

    func test_makeCopyDraftWholeMealCopiesAllItemsAndProjectsTotalsFromItems() async throws {
        let store = makeStore(now: { 1111 })
        let source = MealStore.Snapshot(
            meal: makeMeal(
                mealType: .lunch,
                eatenAt: 100,
                caloriesKcal: 10.5,
                proteinG: 8.5,
                fatG: 0,
                carbsG: 3,
                photoPath: "legacy-photo.jpg",
                notes: "legacy-notes",
                createdAt: 999,
                hkSyncId: "legacy-sync"
            ),
            items: [
                MealItemRecord(
                    id: 1,
                    mealId: 2,
                    sortOrder: 1,
                    name: "Egg",
                    grams: 100,
                    preparationState: .raw,
                    caloriesKcal: 50,
                    proteinG: 0,
                    fatG: nil,
                    carbsG: 20,
                    provenanceKind: .aiEstimate,
                    provenanceRef: "ref-1",
                    provenanceVersion: "v1",
                    confidence: .high,
                    isUserEdited: true,
                    createdAt: 111,
                    updatedAt: 111
                ),
                MealItemRecord(
                    id: 2,
                    mealId: 2,
                    sortOrder: 0,
                    name: "Rice",
                    grams: 50,
                    preparationState: .cooked,
                    caloriesKcal: 100,
                    proteinG: 4,
                    fatG: 5,
                    carbsG: nil,
                    provenanceKind: .nutritionLabel,
                    provenanceRef: "ref-2",
                    provenanceVersion: "v2",
                    confidence: .medium,
                    isUserEdited: false,
                    createdAt: 111,
                    updatedAt: 111
                )
            ]
        )
        let sourceBefore = source

        let draft = try store.makeCopyDraft(
            from: source,
            selection: .wholeMeal,
            targetMealType: .dinner,
            eatenAt: 200
        )

        XCTAssertNil(draft.meal.id)
        XCTAssertNil(draft.meal.photoPath)
        XCTAssertNil(draft.meal.notes)
        XCTAssertNil(draft.meal.hkSyncId)
        XCTAssertEqual(draft.meal.mealType, MealRecord.MealType.dinner)
        XCTAssertEqual(draft.meal.eatenAt, 200)
        XCTAssertEqual(draft.meal.createdAt, 1111)
        XCTAssertEqual(draft.meal.caloriesKcal, 150)
        XCTAssertEqual(draft.meal.proteinG, 4)
        XCTAssertNil(draft.meal.fatG)
        XCTAssertNil(draft.meal.carbsG)
        XCTAssertEqual(draft.items.map(\.name), ["Rice", "Egg"])
        XCTAssertEqual(draft.items.map(\.grams), [50, 100])
        XCTAssertEqual(draft.items.map(\.preparationState), [.cooked, .raw])
        XCTAssertEqual(draft.items[0].provenanceKind, .nutritionLabel)
        XCTAssertEqual(draft.items[0].provenanceRef, "ref-2")
        XCTAssertEqual(draft.items[0].provenanceVersion, "v2")
        XCTAssertEqual(draft.items[0].confidence, .medium)
        XCTAssertFalse(draft.items[0].isUserEdited)
        XCTAssertEqual(draft.items[1].provenanceKind, .aiEstimate)
        XCTAssertEqual(draft.items[1].provenanceRef, "ref-1")
        XCTAssertEqual(draft.items[1].provenanceVersion, "v1")
        XCTAssertEqual(draft.items[1].confidence, .high)
        XCTAssertTrue(draft.items[1].isUserEdited)
        XCTAssertEqual(draft.items[0].caloriesKcal, 100)
        XCTAssertEqual(draft.items[0].proteinG, 4)
        XCTAssertEqual(draft.items[0].fatG, 5)
        XCTAssertNil(draft.items[0].carbsG)
        XCTAssertEqual(draft.items[1].caloriesKcal, 50)
        XCTAssertEqual(draft.items[1].proteinG, 0)
        XCTAssertNil(draft.items[1].fatG)
        XCTAssertEqual(draft.items[1].carbsG, 20)
        XCTAssertNil(draft.items[0].createdAt)
        XCTAssertNil(draft.items[1].createdAt)
        XCTAssertEqual(source, sourceBefore)
    }

    func test_makeCopyDraft_legacyZeroItemMealKeepsOriginalTotals() async throws {
        let store = makeStore()
        let source = try await store.save(
            meal: makeMeal(
                mealType: .breakfast,
                eatenAt: 1000,
                caloriesKcal: 10.5,
                proteinG: 0,
                fatG: nil,
                carbsG: 3.5,
                photoPath: "legacy.jpg",
                notes: "legacy-notes",
                createdAt: 1000,
                hkSyncId: "legacy-sync"
            ),
            items: []
        )

        let draft = try store.makeCopyDraft(
            from: source,
            selection: .wholeMeal,
            targetMealType: .snack,
            eatenAt: 2000
        )

        XCTAssertNotNil(source.meal.id)
        XCTAssertNil(draft.meal.id)
        XCTAssertTrue(draft.items.isEmpty)
        XCTAssertEqual(draft.meal.caloriesKcal, 10.5)
        XCTAssertEqual(draft.meal.proteinG, 0)
        XCTAssertNil(draft.meal.fatG)
        XCTAssertEqual(draft.meal.carbsG, 3.5)
        XCTAssertNil(draft.meal.photoPath)
        XCTAssertNil(draft.meal.notes)
        XCTAssertNil(draft.meal.hkSyncId)
    }

    func test_makeCopyDraftSelectedItemsUsesSortOrderAndValidatesClockUsage() async throws {
        let source = MealStore.Snapshot(
            meal: makeMeal(
                mealType: .dinner,
                eatenAt: 100,
                caloriesKcal: 60,
                proteinG: 12,
                fatG: 8,
                carbsG: 15,
                createdAt: 999
            ),
            items: [
                MealItemRecord(
                    id: 10,
                    mealId: 11,
                    sortOrder: 3,
                    name: "Third",
                    grams: 30,
                    preparationState: .raw,
                    caloriesKcal: 30,
                    proteinG: 3,
                    fatG: 3,
                    carbsG: 3,
                    provenanceKind: .manual,
                    isUserEdited: false,
                    createdAt: 111,
                    updatedAt: 111
                ),
                MealItemRecord(
                    id: 11,
                    mealId: 11,
                    sortOrder: 1,
                    name: "First",
                    grams: 10,
                    preparationState: .raw,
                    caloriesKcal: 10,
                    proteinG: 1,
                    fatG: 1,
                    carbsG: 1,
                    provenanceKind: .manual,
                    isUserEdited: false,
                    createdAt: 111,
                    updatedAt: 111
                ),
                MealItemRecord(
                    id: 12,
                    mealId: 11,
                    sortOrder: 2,
                    name: "Second",
                    grams: 20,
                    preparationState: .raw,
                    caloriesKcal: 20,
                    proteinG: 2,
                    fatG: 2,
                    carbsG: 2,
                    provenanceKind: .manual,
                    isUserEdited: false,
                    createdAt: 111,
                    updatedAt: 111
                )
            ]
        )

        let successClock = ThreadSafeClock(reading: 2222)
        let store = makeStore(now: { successClock.read() })
        let selectedDraft = try store.makeCopyDraft(
            from: source,
            selection: .itemIds([12, 11]),
            targetMealType: .snack,
            eatenAt: 200
        )
        XCTAssertEqual(successClock.readCount, 1)
        XCTAssertEqual(selectedDraft.items.map(\.name), ["First", "Second"])
        XCTAssertEqual(selectedDraft.meal.caloriesKcal, 30)
        XCTAssertEqual(selectedDraft.meal.proteinG, 3)
        XCTAssertEqual(selectedDraft.meal.fatG, 3)
        XCTAssertEqual(selectedDraft.meal.carbsG, 3)

        let failureClock = ThreadSafeClock(reading: 3333)
        let failureStore = makeStore(now: { failureClock.read() })
        do {
            _ = try failureStore.makeCopyDraft(
                from: source,
                selection: .itemIds([]),
                targetMealType: .snack,
                eatenAt: 210
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MealStore.ReuseError, .emptySelection)
            XCTAssertEqual(failureClock.readCount, 0)
        }

        do {
            _ = try failureStore.makeCopyDraft(
                from: source,
                selection: .itemIds([101, 15, 99]),
                targetMealType: .snack,
                eatenAt: 220
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(
                error as? MealStore.ReuseError,
                .missingItemIds([15, 99, 101])
            )
            XCTAssertEqual(failureClock.readCount, 0)
        }
    }
}

private func makeStore(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) -> MealStore {
    MealStore(databaseManager: DatabaseManager.makeInMemoryForTesting(), now: now)
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

private final class ThreadSafeClock: @unchecked Sendable {
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
