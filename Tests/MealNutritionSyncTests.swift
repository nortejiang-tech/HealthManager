import XCTest
import GRDB
@testable import HealthManager

/// Guards the selection SQL that `SyncEngine.pushMealNutritionToHealth` uses to decide
/// which meals still need to be written to Apple Health: only meals that carry at least one
/// macro AND have not yet been synced (`hk_sync_id IS NULL`).
final class MealNutritionSyncTests: XCTestCase {

    private var db: DatabaseManager!

    override func setUp() {
        super.setUp()
        db = DatabaseManager.makeInMemoryForTesting()
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    @discardableResult
    private func insertMeal(calories: Double? = nil, protein: Double? = nil,
                            fat: Double? = nil, carbs: Double? = nil,
                            eatenAt: Int64 = 1_000, hkSyncId: String?) throws -> Int64 {
        try db.write { dbc in
            var m = MealRecord(
                id: nil, mealType: .lunch, eatenAt: eatenAt,
                caloriesKcal: calories, proteinG: protein, fatG: fat, carbsG: carbs,
                photoPath: nil, notes: nil, createdAt: 0, hkSyncId: hkSyncId
            )
            try m.insert(dbc)
            return m.id!
        }
    }

    /// Mirrors the exact filter used in SyncEngine.pushMealNutritionToHealth.
    private func selectUnsyncedWithMacros() throws -> [MealRecord] {
        try db.read { dbc in
            try MealRecord
                .filter(sql: "(calories_kcal IS NOT NULL OR protein_g IS NOT NULL OR fat_g IS NOT NULL OR carbs_g IS NOT NULL) AND hk_sync_id IS NULL")
                .order(Column("eaten_at").desc)
                .fetchAll(dbc)
        }
    }

    func test_selection_picksOnlyUnsyncedMealsThatHaveMacros() throws {
        let wantA = try insertMeal(calories: 300, eatenAt: 4_000, hkSyncId: nil)   // ✓ unsynced + calories
        try insertMeal(calories: 300, eatenAt: 3_000, hkSyncId: "meal-99")         // ✗ already synced
        let wantB = try insertMeal(protein: 20, eatenAt: 2_000, hkSyncId: nil)     // ✓ unsynced + protein only
        try insertMeal(eatenAt: 1_000, hkSyncId: nil)                             // ✗ no macros at all

        let selected = try selectUnsyncedWithMacros()

        XCTAssertEqual(selected.map(\.id), [wantA, wantB], "ordered by eaten_at desc, synced/macro-less excluded")
        XCTAssertTrue(selected.allSatisfy { $0.hkSyncId == nil })
        XCTAssertTrue(selected.allSatisfy {
            $0.caloriesKcal != nil || $0.proteinG != nil || $0.fatG != nil || $0.carbsG != nil
        })
    }

    func test_selection_empty_whenAllSyncedOrMacroLess() throws {
        try insertMeal(calories: 250, hkSyncId: "meal-1")   // synced
        try insertMeal(hkSyncId: nil)                       // no macros
        XCTAssertTrue(try selectUnsyncedWithMacros().isEmpty)
    }
}
