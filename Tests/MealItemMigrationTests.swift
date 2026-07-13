import XCTest
import GRDB
@testable import HealthManager

final class MealItemMigrationTests: XCTestCase {
    private func makeMigratedPool(upTo migration: String? = nil) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-stage001-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: url.path, configuration: configuration)

        var migrator = Migrations.makeMigrator()
        if let migration = migration {
            try migrator.migrate(pool, upTo: migration)
        } else {
            try migrator.migrate(pool)
        }
        return pool
    }

    private func insertLegacyMeal(
        pool: DatabasePool,
        mealType: MealRecord.MealType = .lunch,
        eatenAt: Int64 = 1_000_000,
        calories: Double? = 280,
        protein: Double? = 15,
        fat: Double? = 9,
        carbs: Double? = 40,
        photoPath: String? = "photo1.png",
        notes: String? = "notes",
        hkSyncId: String? = "hk-sync-1"
    ) throws -> Int64 {
        var meal = MealRecord(
            id: nil,
            mealType: mealType,
            eatenAt: eatenAt,
            caloriesKcal: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            photoPath: photoPath,
            notes: notes,
            createdAt: 1_111_111,
            hkSyncId: hkSyncId
        )

        try pool.write { db in
            try meal.insert(db)
        }

        return meal.id!
    }

    private func insertMealItem(
        pool: DatabasePool,
        mealId: Int64,
        sortOrder: Int,
        name: String = "Item",
        grams: Double? = 100,
        preparationState: MealItemRecord.PreparationState = .unknown,
        calories: Double? = nil,
        protein: Double? = nil,
        fat: Double? = nil,
        carbs: Double? = nil,
        provenanceKind: MealItemRecord.ProvenanceKind = .manual,
        provenanceRef: String? = nil,
        provenanceVersion: String? = nil,
        confidence: MealItemRecord.Confidence? = nil,
        isUserEdited: Bool = false,
        createdAt: Int64 = 1_222_222,
        updatedAt: Int64 = 1_333_333
    ) throws {
        var item = MealItemRecord(
            id: nil,
            mealId: mealId,
            sortOrder: sortOrder,
            name: name,
            grams: grams,
            preparationState: preparationState,
            caloriesKcal: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            provenanceKind: provenanceKind,
            provenanceRef: provenanceRef,
            provenanceVersion: provenanceVersion,
            confidence: confidence,
            isUserEdited: isUserEdited,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        try pool.write { db in
            try item.insert(db)
        }
    }

    private func insertRawMealItem(
        pool: DatabasePool,
        mealId: Int64,
        sortOrder: Int = 0,
        name: String = "Name",
        grams: Double = 100,
        preparationState: String = "raw",
        caloriesKcal: Double = 10,
        provenanceKind: String = "manual",
        confidence: String? = "low"
    ) throws {
        let arguments: [DatabaseValueConvertible] = [
            mealId, sortOrder, name, grams, preparationState,
            caloriesKcal, 1.0, 1.0, 1.0,
            provenanceKind, "ref", "v1", confidence,
            0, Int64(1), Int64(1)
        ]
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, grams, preparation_state, calories_kcal, protein_g, fat_g, carbs_g, provenance_kind, provenance_ref, provenance_version, confidence, is_user_edited, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func assertConstraintFailure(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () throws -> Void
    ) {
        XCTAssertThrowsError(try block(), file: file, line: line)
    }

    func test_migrateFromV4_preservesLegacyMealFieldsAndKeepsNoMealItems() throws {
        let pool = try makeMigratedPool(upTo: "v4_meal_hk_sync_id")
        let mealId = try insertLegacyMeal(pool: pool)

        try Migrations.run(on: pool)

        let legacyMeal = try pool.read { db in
            try MealRecord.fetchOne(db, key: mealId)
        }
        XCTAssertNotNil(legacyMeal)

        XCTAssertEqual(legacyMeal?.mealType, .lunch)
        XCTAssertEqual(legacyMeal?.eatenAt, 1_000_000)
        XCTAssertEqual(legacyMeal?.caloriesKcal, 280)
        XCTAssertEqual(legacyMeal?.proteinG, 15)
        XCTAssertEqual(legacyMeal?.fatG, 9)
        XCTAssertEqual(legacyMeal?.carbsG, 40)
        XCTAssertEqual(legacyMeal?.photoPath, "photo1.png")
        XCTAssertEqual(legacyMeal?.notes, "notes")
        XCTAssertEqual(legacyMeal?.hkSyncId, "hk-sync-1")

        let mealItemCount = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM meal_items")!
        }
        XCTAssertEqual(mealItemCount, 0)
    }

    func test_mealItemRecord_roundTripsEnumsAndNullableFieldsWithoutDefaultingNulls() throws {
        struct ExpectedTrip {
            let sortOrder: Int
            let preparationState: MealItemRecord.PreparationState
            let provenanceKind: MealItemRecord.ProvenanceKind
            let confidence: MealItemRecord.Confidence?
            let grams: Double
            let caloriesKcal: Double
            let proteinG: Double
            let fatG: Double
            let carbsG: Double
            let provenanceRef: String?
            let provenanceVersion: String?
            let isUserEdited: Bool
            let createdAt: Int64
            let updatedAt: Int64
        }

        let pool = try makeMigratedPool()
        let mealId = try insertLegacyMeal(pool: pool)

        let confidenceValues: [MealItemRecord.Confidence?] = [.low, .medium, .high, nil]
        var expectedTriplets: [ExpectedTrip] = []
        var sortOrder = 0

        for preparationState in MealItemRecord.PreparationState.allCases {
            for provenanceKind in MealItemRecord.ProvenanceKind.allCases {
                for confidence in confidenceValues {
                    let isUserEdited = sortOrder % 2 == 0
                    let expectedCreatedAt = Int64(2_000_000 + sortOrder)
                    let expectedUpdatedAt = Int64(3_000_000 + sortOrder)
                    expectedTriplets.append(
                        ExpectedTrip(
                            sortOrder: sortOrder,
                            preparationState: preparationState,
                            provenanceKind: provenanceKind,
                            confidence: confidence,
                            grams: 120,
                            caloriesKcal: 500,
                            proteinG: 35,
                            fatG: 12,
                            carbsG: 45,
                            provenanceRef: "ref-\(sortOrder)",
                            provenanceVersion: "v1",
                            isUserEdited: isUserEdited,
                            createdAt: expectedCreatedAt,
                            updatedAt: expectedUpdatedAt
                        )
                    )
                    try insertMealItem(
                        pool: pool,
                        mealId: mealId,
                        sortOrder: sortOrder,
                        name: "\(preparationState.rawValue)-\(provenanceKind.rawValue)-\(sortOrder)",
                        grams: 120,
                        preparationState: preparationState,
                        calories: 500,
                        protein: 35,
                        fat: 12,
                        carbs: 45,
                        provenanceKind: provenanceKind,
                        provenanceRef: "ref-\(sortOrder)",
                        provenanceVersion: "v1",
                        confidence: confidence,
                        isUserEdited: isUserEdited,
                        createdAt: expectedCreatedAt,
                        updatedAt: expectedUpdatedAt
                    )
                    sortOrder += 1
                }
            }
        }

        var nullMealItem = MealItemRecord(
            id: nil,
            mealId: mealId,
            sortOrder: sortOrder,
            name: "nil-item",
            grams: nil,
            preparationState: .unknown,
            caloriesKcal: nil,
            proteinG: nil,
            fatG: nil,
            carbsG: nil,
            provenanceKind: .manual,
            provenanceRef: nil,
            provenanceVersion: nil,
            confidence: nil,
            isUserEdited: false,
            createdAt: 2_222_222,
            updatedAt: 2_333_333
        )
        try pool.write { db in
            try nullMealItem.insert(db)
        }

        let allItems = try pool.read { db in
            try MealItemRecord.order(Column("sort_order")).fetchAll(db)
        }
        XCTAssertEqual(allItems.count, confidenceValues.count * MealItemRecord.PreparationState.allCases.count * MealItemRecord.ProvenanceKind.allCases.count + 1)

        for expected in expectedTriplets {
            let actual = try XCTUnwrap(allItems.first { $0.sortOrder == expected.sortOrder })
            XCTAssertEqual(actual.preparationState, expected.preparationState)
            XCTAssertEqual(actual.provenanceKind, expected.provenanceKind)
            XCTAssertEqual(actual.confidence, expected.confidence)
            XCTAssertEqual(actual.grams, expected.grams)
            XCTAssertEqual(actual.caloriesKcal, expected.caloriesKcal)
            XCTAssertEqual(actual.proteinG, expected.proteinG)
            XCTAssertEqual(actual.fatG, expected.fatG)
            XCTAssertEqual(actual.carbsG, expected.carbsG)
            XCTAssertEqual(actual.provenanceRef, expected.provenanceRef)
            XCTAssertEqual(actual.provenanceVersion, expected.provenanceVersion)
            XCTAssertEqual(actual.isUserEdited, expected.isUserEdited)
            XCTAssertEqual(actual.createdAt, expected.createdAt)
            XCTAssertEqual(actual.updatedAt, expected.updatedAt)
        }

        let nilMealItemActual = try XCTUnwrap(allItems.first { $0.name == "nil-item" })
        XCTAssertNil(nilMealItemActual.grams)
        XCTAssertNil(nilMealItemActual.caloriesKcal)
        XCTAssertNil(nilMealItemActual.proteinG)
        XCTAssertNil(nilMealItemActual.fatG)
        XCTAssertNil(nilMealItemActual.carbsG)
        XCTAssertNil(nilMealItemActual.provenanceRef)
        XCTAssertNil(nilMealItemActual.provenanceVersion)
        XCTAssertNil(nilMealItemActual.confidence)

    }

    func test_sortOrderQueriesAreOrdered_andSortOrderUniqueConstraintWorks() throws {
        let pool = try makeMigratedPool()
        let mealId = try insertLegacyMeal(pool: pool, photoPath: nil, notes: nil)

        try insertMealItem(pool: pool, mealId: mealId, sortOrder: 2, name: "third")
        try insertMealItem(pool: pool, mealId: mealId, sortOrder: 0, name: "first")
        try insertMealItem(pool: pool, mealId: mealId, sortOrder: 1, name: "second")

        let ordered = try pool.read { db in
            try MealItemRecord
                .filter(Column("meal_id") == mealId)
                .order(Column("sort_order").asc)
                .fetchAll(db)
        }
        XCTAssertEqual(ordered.map { $0.sortOrder }, [0, 1, 2])
        XCTAssertEqual(ordered.map { $0.name }, ["first", "second", "third"])

        assertConstraintFailure {
            try insertMealItem(pool: pool, mealId: mealId, sortOrder: 1, name: "duplicate")
        }
    }

    func test_invalidValuesAreRejectedByDatabase() throws {
        let pool = try makeMigratedPool()
        let mealId = try insertLegacyMeal(pool: pool)

        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, name: "   ")
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, sortOrder: -1)
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, grams: 0)
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, caloriesKcal: -10)
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, preparationState: "fried")
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, provenanceKind: "illegal")
        }
        assertConstraintFailure {
            try insertRawMealItem(pool: pool, mealId: mealId, confidence: "super-high")
        }
    }

    func test_invalidMealIdIsRejectedAndCascadeDeleteClearsChildren() throws {
        let pool = try makeMigratedPool()
        let mealId = try insertLegacyMeal(pool: pool)

        assertConstraintFailure {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, preparation_state, provenance_kind, is_user_edited, created_at, updated_at)
                    VALUES (?, 1, 'Ghost', 'unknown', 'manual', 0, 1, 1)
                    """, arguments: [mealId + 10_000])
            }
        }

        try insertMealItem(pool: pool, mealId: mealId, sortOrder: 0, name: "valid")

        let countBeforeDelete = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM meal_items")!
        }
        XCTAssertEqual(countBeforeDelete, 1)

        try pool.write { db in
            try db.execute(sql: "DELETE FROM meal_records WHERE id = ?", arguments: [mealId])
        }

        let countAfterDelete = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM meal_items")!
        }
        XCTAssertEqual(countAfterDelete, 0)
    }
}
