import Foundation

final class MealPersistenceCoordinator {
    typealias NutritionWriter = (MealRecord) async -> HealthKitManager.NutritionWriteResult
    typealias PhotoRemover = (String) -> Void
    typealias NutritionDeletion = (String) async -> Void

    private let mealStore: MealStore
    private let writeNutritionToHealth: NutritionWriter
    private let removePhotoIfManaged: PhotoRemover
    private let deleteHealthKitSamples: NutritionDeletion

    init(
        mealStore: MealStore,
        writeNutritionToHealth: @escaping NutritionWriter,
        removePhotoIfManaged: @escaping PhotoRemover,
        deleteHealthKitSamples: @escaping NutritionDeletion
    ) {
        self.mealStore = mealStore
        self.writeNutritionToHealth = writeNutritionToHealth
        self.removePhotoIfManaged = removePhotoIfManaged
        self.deleteHealthKitSamples = deleteHealthKitSamples
    }

    convenience init(mealStore: MealStore, healthKitManager: HealthKitManager, mealPhotoStore: MealPhotoStore = .shared) {
        self.init(
            mealStore: mealStore,
            writeNutritionToHealth: { meal in
                await healthKitManager.syncMealNutrition(
                    eatenAt: meal.eatenAt,
                    calories: meal.caloriesKcal,
                    protein: meal.proteinG,
                    fat: meal.fatG,
                    carbs: meal.carbsG,
                    name: meal.notes ?? meal.mealType.label,
                    existingSyncId: meal.hkSyncId ?? meal.id.map { "meal-\($0)" }
                )
            },
            removePhotoIfManaged: mealPhotoStore.removeIfManaged(path:),
            deleteHealthKitSamples: { syncId in
                await healthKitManager.deleteNutritionSamples(syncId: syncId)
            }
        )
    }

    /// Save a meal with draft-derived items atomically in SQLite, then sync HealthKit.
    /// Side effects (photo cleanup, HealthKit write, sync-id persistence) happen only
    /// after successful DB save.
    func save(
        meal: MealRecord,
        drafts: [MealItemDraft],
        originalPhotoPaths: [String]
    ) async throws -> MealStore.Snapshot {
        let inputs = try drafts.map { try $0.toItemInput() }
        let saved = try await mealStore.save(meal: meal, items: inputs)

        let stillKept = Set(saved.meal.photoPaths)
        for old in Set(originalPhotoPaths) where !stillKept.contains(old) {
            removePhotoIfManaged(old)
        }

        let writeResult = await writeNutritionToHealth(saved.meal)
        guard case .written(let syncId) = writeResult else { return saved }
        guard let id = saved.meal.id else { return saved }
        do {
            let persisted = try await mealStore.saveSyncId(mealId: id, syncId: syncId)
            return MealStore.Snapshot(meal: persisted, items: saved.items)
        } catch {
            AppLogger.shared.error("Persist meal hk_sync_id failed: \(error.localizedDescription)")
            return saved
        }
    }

    /// Delete a meal, returning from SQLite before any external side effects.
    func delete(mealId: Int64) async throws {
        let snapshot = try await mealStore.delete(id: mealId)
        guard let snapshot else { return }

        for path in snapshot.meal.photoPaths {
            removePhotoIfManaged(path)
        }

        if let hkSyncId = snapshot.meal.hkSyncId {
            await deleteHealthKitSamples(hkSyncId)
        }
    }
}
