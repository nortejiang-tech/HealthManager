import Foundation
import UIKit

struct MealEditorDraft {
    struct MealPhotoDraft: Identifiable, Equatable {
        let id: UUID = UUID()
        let path: String
        var image: UIImage?
        let isSessionCreated: Bool
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case invalidParentValue(field: String, raw: String)

        var errorDescription: String? {
            switch self {
            case .invalidParentValue(let field, let raw):
                "\(field)输入无效：\(raw)"
            }
        }
    }

    enum LoadState: Equatable {
        case ready
        case loading
        case failed(String)
    }

    var id: Int64?
    var mealType: MealRecord.MealType
    var eatenAt: Date
    var caloriesText: String
    var proteinText: String
    var fatText: String
    var carbsText: String
    var notes: String
    var nutritionItems: [MealItemDraft]
    var photoDrafts: [MealPhotoDraft]

    private(set) var itemTotals: MealNutritionTotals?
    private(set) var originalPhotoPaths: [String]
    var createdAt: Int64
    var hkSyncId: String?
    var loadState: LoadState

    init(meal: MealRecord?, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        if let meal {
            guard let mealId = meal.id else {
                self.id = nil
                self.mealType = meal.mealType
                self.eatenAt = Date(timeIntervalSince1970: TimeInterval(meal.eatenAt))
                self.caloriesText = Self.formatMealValue(meal.caloriesKcal)
                self.proteinText = Self.formatMealValue(meal.proteinG)
                self.fatText = Self.formatMealValue(meal.fatG)
                self.carbsText = Self.formatMealValue(meal.carbsG)
                self.notes = meal.notes ?? ""
                self.nutritionItems = []
                self.photoDrafts = Self.photoDrafts(from: meal.photoPaths, loadImage: { _ in nil })
                self.itemTotals = nil
                self.originalPhotoPaths = meal.photoPaths
                self.createdAt = meal.createdAt
                self.hkSyncId = meal.hkSyncId
                self.loadState = .failed("该餐次缺少 ID，无法编辑已有记录")
                return
            }

            self.id = mealId
            self.mealType = meal.mealType
            self.eatenAt = Date(timeIntervalSince1970: TimeInterval(meal.eatenAt))
            self.caloriesText = Self.formatMealValue(meal.caloriesKcal)
            self.proteinText = Self.formatMealValue(meal.proteinG)
            self.fatText = Self.formatMealValue(meal.fatG)
            self.carbsText = Self.formatMealValue(meal.carbsG)
            self.notes = meal.notes ?? ""
            self.nutritionItems = []
            self.photoDrafts = []
            self.itemTotals = nil
            self.originalPhotoPaths = meal.photoPaths
            self.createdAt = meal.createdAt
            self.hkSyncId = meal.hkSyncId
            self.loadState = .loading
            return
        }

        self.id = nil
        self.mealType = MealRecord.MealType.suggested()
        self.eatenAt = Date()
        self.caloriesText = ""
        self.proteinText = ""
        self.fatText = ""
        self.carbsText = ""
        self.notes = ""
        self.nutritionItems = []
        self.photoDrafts = []
        self.itemTotals = nil
        self.originalPhotoPaths = []
        self.createdAt = now()
        self.hkSyncId = nil
        self.loadState = .ready
    }

    var canSave: Bool {
        loadState == .ready
    }

    var isManualSummaryMode: Bool {
        nutritionItems.isEmpty
    }

    var hasUnsubmittedSessionPhotos: Bool {
        photoDrafts.contains(where: { $0.isSessionCreated })
    }

    var allPhotoPaths: [String] {
        photoDrafts.map(\.path)
    }

    var sessionCreatedPhotoPaths: [String] {
        photoDrafts.filter(\.isSessionCreated).map(\.path)
    }

    mutating func markLoadFailure(_ message: String) {
        loadState = .failed(message)
    }

    mutating func reconcileTotalsFromItems() {
        if nutritionItems.isEmpty, let previousTotals = itemTotals {
            caloriesText = Self.formatMealValue(previousTotals.caloriesKcal)
            proteinText = Self.formatMealValue(previousTotals.proteinG)
            fatText = Self.formatMealValue(previousTotals.fatG)
            carbsText = Self.formatMealValue(previousTotals.carbsG)
        }

        itemTotals = MealNutritionProjection.project(
            nutritionItems.map {
                MealNutritionValues(
                    caloriesKcal: $0.calories,
                    proteinG: $0.protein,
                    fatG: $0.fat,
                    carbsG: $0.carbs
                )
            }
        )
    }

    mutating func apply(snapshot: MealStore.Snapshot, loadImage: (String) -> UIImage?) {
        let meal = snapshot.meal
        id = meal.id
        mealType = meal.mealType
        eatenAt = Date(timeIntervalSince1970: TimeInterval(meal.eatenAt))
        caloriesText = Self.formatMealValue(meal.caloriesKcal)
        proteinText = Self.formatMealValue(meal.proteinG)
        fatText = Self.formatMealValue(meal.fatG)
        carbsText = Self.formatMealValue(meal.carbsG)
        notes = meal.notes ?? ""
        createdAt = meal.createdAt
        hkSyncId = meal.hkSyncId
        nutritionItems = snapshot.items.map(MealItemDraft.init)
        photoDrafts = Self.photoDrafts(from: meal.photoPaths, loadImage: loadImage)
        originalPhotoPaths = meal.photoPaths
        itemTotals = Self.projectTotals(from: snapshot.items)
        loadState = .ready
    }

    mutating func removePhoto(at index: Int) -> MealPhotoDraft? {
        guard photoDrafts.indices.contains(index) else { return nil }
        return photoDrafts.remove(at: index)
    }

    func makeMealRecord() throws -> MealRecord {
        let calories: Double?
        let protein: Double?
        let fat: Double?
        let carbs: Double?

        if isManualSummaryMode {
            calories = try resolveSummary(valueText: caloriesText, field: "热量")
            protein = try resolveSummary(valueText: proteinText, field: "蛋白质")
            fat = try resolveSummary(valueText: fatText, field: "脂肪")
            carbs = try resolveSummary(valueText: carbsText, field: "碳水")
        } else {
            calories = itemTotals?.caloriesKcal
            protein = itemTotals?.proteinG
            fat = itemTotals?.fatG
            carbs = itemTotals?.carbsG
        }

        return MealRecord(
            id: id,
            mealType: mealType,
            eatenAt: Int64(eatenAt.timeIntervalSince1970),
            caloriesKcal: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            photoPath: allPhotoPaths.isEmpty ? nil : allPhotoPaths.joined(separator: ","),
            notes: notes.isEmpty ? nil : notes,
            createdAt: createdAt,
            hkSyncId: hkSyncId
        )
    }

    func parentDisplayLabel(for value: Double?) -> String {
        guard let value else { return "—" }
        return Self.formatMealValue(value)
    }

    static func userFacingSaveError(_ error: Error) -> String {
        if let validationError = error as? ValidationError {
            return validationError.localizedDescription
        }
        if let itemError = error as? MealItemDraft.ValidationError {
            switch itemError {
            case .invalidGrams(let raw):
                return "菜品克数输入无效：\(raw)"
            }
        }
        if let storeError = error as? MealStoreError {
            switch storeError {
            case .mealNotFound:
                return "该餐次不存在或已被删除"
            case .missingMealIdAfterInsert:
                return "保存失败：数据库未返回餐次 ID"
            case .blankItemName(let index):
                return "第 \(index + 1) 个菜品名称不能为空"
            case .blankSyncId:
                return "保存失败：HealthKit 同步标识为空"
            }
        }
        return "保存失败：\(error.localizedDescription)"
    }

    static func photoDrafts(
        from paths: [String],
        loadImage: (String) -> UIImage?
    ) -> [MealPhotoDraft] {
        paths.map {
            MealPhotoDraft(path: $0, image: loadImage($0), isSessionCreated: false)
        }
    }

    private static func projectTotals(from items: [MealItemRecord]) -> MealNutritionTotals? {
        MealNutritionProjection.project(
            items.map {
                MealNutritionValues(
                    caloriesKcal: $0.caloriesKcal,
                    proteinG: $0.proteinG,
                    fatG: $0.fatG,
                    carbsG: $0.carbsG
                )
            }
        )
    }

    private func resolveSummary(valueText: String, field: String) throws -> Double? {
        let trimmed = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let value = Double(trimmed), value.isFinite else {
            throw ValidationError.invalidParentValue(field: field, raw: trimmed)
        }
        guard value >= 0 else {
            throw ValidationError.invalidParentValue(field: field, raw: trimmed)
        }
        return value
    }

    private static func formatMealValue(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }
}
