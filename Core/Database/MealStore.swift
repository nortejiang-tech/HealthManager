import Foundation
import GRDB

enum MealStoreError: Error, Equatable {
    case mealNotFound(Int64)
    case missingMealIdAfterInsert
    case blankItemName(index: Int)
    case blankSyncId
}

final class MealStore: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let meal: MealRecord
        let items: [MealItemRecord]
    }

    struct ItemInput: Equatable, Sendable {
        let name: String
        let grams: Double?
        let preparationState: MealItemRecord.PreparationState
        let caloriesKcal: Double?
        let proteinG: Double?
        let fatG: Double?
        let carbsG: Double?
        let provenanceKind: MealItemRecord.ProvenanceKind
        let provenanceRef: String?
        let provenanceVersion: String?
        let confidence: MealItemRecord.Confidence?
        let isUserEdited: Bool
        let createdAt: Int64?

        init(
            name: String,
            grams: Double? = nil,
            preparationState: MealItemRecord.PreparationState = .unknown,
            caloriesKcal: Double? = nil,
            proteinG: Double? = nil,
            fatG: Double? = nil,
            carbsG: Double? = nil,
            provenanceKind: MealItemRecord.ProvenanceKind = .manual,
            provenanceRef: String? = nil,
            provenanceVersion: String? = nil,
            confidence: MealItemRecord.Confidence? = nil,
            isUserEdited: Bool = false,
            createdAt: Int64? = nil
        ) {
            self.name = name
            self.grams = grams
            self.preparationState = preparationState
            self.caloriesKcal = caloriesKcal
            self.proteinG = proteinG
            self.fatG = fatG
            self.carbsG = carbsG
            self.provenanceKind = provenanceKind
            self.provenanceRef = provenanceRef
            self.provenanceVersion = provenanceVersion
            self.confidence = confidence
            self.isUserEdited = isUserEdited
            self.createdAt = createdAt
        }
    }

    private let databaseManager: DatabaseManager
    private let now: @Sendable () -> Int64

    init(
        databaseManager: DatabaseManager,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.databaseManager = databaseManager
        self.now = now
    }

    func load(id: Int64) async throws -> Snapshot? {
        try await databaseManager.asyncRead { db in
            guard let meal = try MealRecord.fetchOne(db, key: id) else { return nil }
            let items = try MealItemRecord
                .filter(Column("meal_id") == id)
                .order(Column("sort_order"))
                .fetchAll(db)
            return Snapshot(meal: meal, items: items)
        }
    }

    func save(meal: MealRecord, items: [ItemInput]) async throws -> Snapshot {
        try await databaseManager.asyncWrite { [projectedMeal = projectedMeal(meal: meal, items: items), now = self.now] db in
            let timestamp = now()
            let mealId: Int64

            var persistedMeal = projectedMeal
            if let existingId = persistedMeal.id {
                guard (try MealRecord.fetchOne(db, key: existingId)) != nil else {
                    throw MealStoreError.mealNotFound(existingId)
                }
                mealId = existingId
                try persistedMeal.update(db)
            } else {
                try persistedMeal.insert(db)
                guard let insertedId = persistedMeal.id else {
                    throw MealStoreError.missingMealIdAfterInsert
                }
                mealId = insertedId
            }

            try MealItemRecord.filter(Column("meal_id") == mealId).deleteAll(db)

            let preparedItems = try self.prepareItems(
                mealId: mealId,
                items: items,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            for var item in preparedItems {
                try item.insert(db)
            }

            let savedItems = try MealItemRecord
                .filter(Column("meal_id") == mealId)
                .order(Column("sort_order"))
                .fetchAll(db)
            guard let savedMeal = try MealRecord.fetchOne(db, key: mealId) else {
                throw MealStoreError.mealNotFound(mealId)
            }
            return Snapshot(meal: savedMeal, items: savedItems)
        }
    }

    func delete(id: Int64) async throws -> Snapshot? {
        try await databaseManager.asyncWrite { db in
            guard let meal = try MealRecord.fetchOne(db, key: id) else { return nil }
            let items = try MealItemRecord
                .filter(Column("meal_id") == id)
                .order(Column("sort_order"))
                .fetchAll(db)
            try MealRecord.deleteOne(db, key: id)
            return Snapshot(meal: meal, items: items)
        }
    }

    func saveSyncId(mealId: Int64, syncId: String) async throws -> MealRecord {
        let trimmed = syncId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MealStoreError.blankSyncId }

        return try await databaseManager.asyncWrite { db in
            guard try MealRecord.fetchOne(db, key: mealId) != nil else {
                throw MealStoreError.mealNotFound(mealId)
            }
            try db.execute(
                sql: "UPDATE meal_records SET hk_sync_id = ? WHERE id = ?",
                arguments: [trimmed, mealId]
            )
            guard let meal = try MealRecord.fetchOne(db, key: mealId) else {
                throw MealStoreError.mealNotFound(mealId)
            }
            return meal
        }
    }

    private func projectedMeal(meal: MealRecord, items: [ItemInput]) -> MealRecord {
        guard !items.isEmpty else { return meal }

        var projectedMeal = meal
        projectedMeal.caloriesKcal = mealAggregate(items: items) { $0.caloriesKcal }
        projectedMeal.proteinG = mealAggregate(items: items) { $0.proteinG }
        projectedMeal.fatG = mealAggregate(items: items) { $0.fatG }
        projectedMeal.carbsG = mealAggregate(items: items) { $0.carbsG }
        return projectedMeal
    }

    private func mealAggregate(items: [ItemInput], _ value: (ItemInput) -> Double?) -> Double? {
        if items.contains(where: { value($0) == nil }) {
            return nil
        }
        return items.compactMap(value).reduce(0, +)
    }

    private func prepareItems(
        mealId: Int64,
        items: [ItemInput],
        createdAt: Int64,
        updatedAt: Int64
    ) throws -> [MealItemRecord] {
        return try items.enumerated().map { index, input in
            let trimmedName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw MealStoreError.blankItemName(index: index) }
            return MealItemRecord(
                id: nil,
                mealId: mealId,
                sortOrder: index,
                name: trimmedName,
                grams: input.grams,
                preparationState: input.preparationState,
                caloriesKcal: input.caloriesKcal,
                proteinG: input.proteinG,
                fatG: input.fatG,
                carbsG: input.carbsG,
                provenanceKind: input.provenanceKind,
                provenanceRef: input.provenanceRef,
                provenanceVersion: input.provenanceVersion,
                confidence: input.confidence,
                isUserEdited: input.isUserEdited,
                createdAt: input.createdAt ?? createdAt,
                updatedAt: updatedAt
            )
        }
    }
}
