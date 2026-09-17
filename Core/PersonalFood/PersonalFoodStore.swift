import Foundation
import GRDB

/// 个人常吃与配方存储（ADR-004）。全部查询走 DatabaseManager 后台执行器；
/// 频次统计每次从餐次表实时重建，不持久化会与历史脱节的排行榜（§5.1）。
final class PersonalFoodStore: @unchecked Sendable {

    enum StoreError: Error, Equatable, LocalizedError {
        case invalidInput(String)
        case recipeNotFound(Int64)
        case foodNotFound(Int64)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let detail):
                return "个人食物输入无效：\(detail)"
            case .recipeNotFound(let id):
                return "配方不存在（\(id)）"
            case .foodNotFound(let id):
                return "个人食物不存在（\(id)）"
            }
        }
    }

    struct MatchedFood: Equatable, Sendable {
        let food: PersonalFoodRecord
        let recentMealCount: Int
        let recentLastEatenAt: Int64?
        let recentCommonGrams: Double?
    }

    struct RecipeWithVersion: Equatable, Sendable {
        let recipe: PersonalRecipeRecord
        let version: PersonalRecipeVersionRecord
        let recentMealCount: Int
    }

    struct FrequentPage: Equatable, Sendable {
        let windowDays: Int?
        let matchedFoods: [MatchedFood]
        let recipes: [RecipeWithVersion]
        let pendingCandidates: [FrequentFoodsQuery.Summary]
    }

    /// 已保存分项引用配方版本的 provenance_ref 前缀。
    static func provenanceRef(recipeId: Int64, version: Int) -> String {
        "recipe:\(recipeId):v\(version)"
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

    // MARK: - 我的常吃页面

    /// 加载「我的常吃」：已匹配单品、配方、待确认候选。
    /// 候选 = 窗口内的分项规范名 −（已被任何映射覆盖 ∪ 已忽略）。
    func loadFrequentPage(windowDays: Int?) async throws -> FrequentPage {
        try await databaseManager.asyncRead { db in
            let facts = try FrequentFoodsQuery.loadMealFacts(db: db, windowDays: windowDays)
            let summaries = FrequentFoodsQuery.summarize(mealFacts: facts)
            let foods = try PersonalFoodRecord.order(Column("pinned").desc).fetchAll(db)
            let ignoredKeys = Set(
                try IgnoredCandidateRecord.fetchAll(db).map(\.candidateKey)
            )
            let recipes = try PersonalRecipeRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)

            // 映射覆盖键 → 最近30天餐数/最近时间/常用克数（并集按餐去重）。
            func stats(forKeys keys: [String]) -> (count: Int, last: Int64?, grams: Double?) {
                let keySet = Set(keys)
                var mealIds = Set<Int64>()
                var last: Int64?
                var gramsCounts: [Double: Int] = [:]
                for fact in facts {
                    let hit = fact.items.contains { keySet.contains(MealItemIdentity.canonicalName($0.name)) }
                    guard hit else { continue }
                    mealIds.insert(fact.mealId)
                    last = max(last ?? 0, fact.eatenAt)
                    for item in fact.items where keySet.contains(MealItemIdentity.canonicalName(item.name)) {
                        if let grams = item.grams, grams > 0, grams.isFinite {
                            gramsCounts[grams, default: 0] += 1
                        }
                    }
                }
                let common = gramsCounts.max {
                    ($0.value, $0.key) < ($1.value, $1.key)
                }?.key
                return (mealIds.count, last, common)
            }

            var matchedFoods: [MatchedFood] = []
            var coveredKeys = Set<String>()
            for food in foods {
                let keys = food.matchKeys
                coveredKeys.formUnion(keys)
                let foodStats = stats(forKeys: keys)
                matchedFoods.append(
                    MatchedFood(
                        food: food,
                        recentMealCount: foodStats.count,
                        recentLastEatenAt: foodStats.last,
                        recentCommonGrams: foodStats.grams
                    )
                )
            }
            // 置顶优先 → 近30天餐数降序 → 名称稳定。
            matchedFoods.sort {
                if $0.food.pinned != $1.food.pinned { return $0.food.pinned }
                if $0.recentMealCount != $1.recentMealCount { return $0.recentMealCount > $1.recentMealCount }
                return $0.food.displayName < $1.food.displayName
            }

            var recipeEntries: [RecipeWithVersion] = []
            for recipe in recipes {
                guard let recipeId = recipe.id else { continue }
                guard let version = try PersonalRecipeVersionRecord
                    .filter(Column("recipe_id") == recipeId)
                    .filter(Column("version") == recipe.currentVersion)
                    .fetchOne(db) else {
                    continue
                }
                let prefix = Self.provenanceRef(recipeId: recipeId, version: version.version)
                var mealCount = 0
                if !facts.isEmpty {
                    // 近30天引用该配方版本的分项所在餐（去重）。
                    let refItems = try MealItemRecord
                        .filter(Column("provenance_kind") == MealItemRecord.ProvenanceKind.recipeCalculation.rawValue)
                        .filter(Column("provenance_ref") == prefix)
                        .fetchAll(db)
                    let refMealIds = Set(refItems.map(\.mealId))
                    mealCount = Set(facts.map(\.mealId)).intersection(refMealIds).count
                }
                recipeEntries.append(
                    RecipeWithVersion(recipe: recipe, version: version, recentMealCount: mealCount)
                )
            }

            let pending = summaries.filter { summary in
                !coveredKeys.contains(summary.key) && !ignoredKeys.contains(summary.key)
            }

            return FrequentPage(
                windowDays: windowDays,
                matchedFoods: matchedFoods,
                recipes: recipeEntries,
                pendingCandidates: pending
            )
        }
    }

    // MARK: - 候选确认 / 忽略

    /// 确认候选 → 映射到官方目录条目。幂等：同一键已确认时更新而非重复创建。
    func confirmCandidate(
        key: String,
        displayName: String,
        entry: FoodCatalogEntry,
        catalogVersion: String
    ) async throws -> PersonalFoodRecord {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedName.isEmpty else {
            throw StoreError.invalidInput("候选名或展示名为空")
        }

        return try await databaseManager.asyncWrite { [now = self.now] db in
            let timestamp = now()
            if var existing = try PersonalFoodRecord
                .filter(Column("kind") == PersonalFoodRecord.Kind.catalog.rawValue)
                .filter(Column("catalog_entry_id") == entry.id)
                .fetchOne(db) {
                var keys = Set(existing.matchKeys)
                keys.insert(trimmedKey)
                existing.matchKeysJSON = PersonalFoodRecord.encodeMatchKeys(Array(keys).sorted())
                existing.updatedAt = timestamp
                try existing.update(db)
                return existing
            }

            var food = PersonalFoodRecord(
                id: nil,
                kind: .catalog,
                displayName: trimmedName,
                matchKeysJSON: PersonalFoodRecord.encodeMatchKeys([trimmedKey]),
                catalogEntryId: entry.id,
                catalogVersion: catalogVersion,
                recipeId: nil,
                defaultGrams: nil,
                pinned: false,
                confirmedAt: timestamp,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try food.insert(db)
            return food
        }
    }

    func ignoreCandidate(key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("候选键为空")
        }
        try await databaseManager.asyncWrite { [now = self.now] db in
            // 幂等：重复忽略同一候选不报错。
            try db.execute(
                sql: "INSERT OR IGNORE INTO ignored_candidates (candidate_key, created_at) VALUES (?, ?)",
                arguments: [trimmed, now()]
            )
        }
    }

    // MARK: - 映射维护

    func setPinned(foodId: Int64, pinned: Bool) async throws {
        try await databaseManager.asyncWrite { db in
            guard var food = try PersonalFoodRecord.fetchOne(db, key: foodId) else {
                throw StoreError.foodNotFound(foodId)
            }
            food.pinned = pinned
            food.updatedAt = self.now()
            try food.update(db)
        }
    }

    func setDefaultGrams(foodId: Int64, grams: Double?) async throws {
        if let grams, !FoodServingCalculator.validGrams(grams) {
            throw StoreError.invalidInput("默认克数必须为正数")
        }
        try await databaseManager.asyncWrite { [now = self.now] db in
            guard var food = try PersonalFoodRecord.fetchOne(db, key: foodId) else {
                throw StoreError.foodNotFound(foodId)
            }
            food.defaultGrams = grams
            food.updatedAt = now()
            try food.update(db)
        }
    }

    func deleteFood(id: Int64) async throws {
        try await databaseManager.asyncWrite { db in
            try PersonalFoodRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - 配方

    /// 创建配方 v1。`matchKey` 非空时同时建立「候选 → 该配方」的映射（确认候选为配方）。
    func createRecipe(
        name: String,
        ingredients: [RecipeIngredient],
        outputGrams: Double?,
        outputWeightBasis: String?,
        note: String?,
        matchKey: String?
    ) async throws -> RecipeWithVersion {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StoreError.invalidInput("配方名称为空")
        }
        guard validate(ingredients: ingredients, outputGrams: outputGrams, outputWeightBasis: outputWeightBasis) else {
            throw StoreError.invalidInput("配方原料或成品重量无效")
        }
        let ingredientsJSON = try PersonalRecipeVersionRecord.encodeIngredients(ingredients)

        return try await databaseManager.asyncWrite { [now = self.now] db in
            let timestamp = now()
            var recipe = PersonalRecipeRecord(
                id: nil,
                displayName: trimmedName,
                currentVersion: 1,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try recipe.insert(db)
            guard let recipeId = recipe.id else {
                throw StoreError.invalidInput("配方插入后未获得 ID")
            }
            var version = PersonalRecipeVersionRecord(
                id: nil,
                recipeId: recipeId,
                version: 1,
                ingredientsJSON: ingredientsJSON,
                outputGrams: outputGrams,
                outputWeightBasis: outputWeightBasis,
                note: note,
                createdAt: timestamp
            )
            try version.insert(db)

            if let matchKey = matchKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !matchKey.isEmpty {
                var food = PersonalFoodRecord(
                    id: nil,
                    kind: .recipe,
                    displayName: trimmedName,
                    matchKeysJSON: PersonalFoodRecord.encodeMatchKeys([matchKey]),
                    catalogEntryId: nil,
                    catalogVersion: nil,
                    recipeId: recipeId,
                    defaultGrams: outputGrams,
                    pinned: false,
                    confirmedAt: timestamp,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                try food.insert(db)
            }

            return RecipeWithVersion(recipe: recipe, version: version, recentMealCount: 0)
        }
    }

    /// 修订配方：生成新版本（version+1），旧版本保留供历史餐次引用。
    func updateRecipe(
        recipeId: Int64,
        name: String,
        ingredients: [RecipeIngredient],
        outputGrams: Double?,
        outputWeightBasis: String?,
        note: String?
    ) async throws -> RecipeWithVersion {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StoreError.invalidInput("配方名称为空")
        }
        guard validate(ingredients: ingredients, outputGrams: outputGrams, outputWeightBasis: outputWeightBasis) else {
            throw StoreError.invalidInput("配方原料或成品重量无效")
        }
        let ingredientsJSON = try PersonalRecipeVersionRecord.encodeIngredients(ingredients)

        return try await databaseManager.asyncWrite { [now = self.now] db in
            guard var recipe = try PersonalRecipeRecord.fetchOne(db, key: recipeId) else {
                throw StoreError.recipeNotFound(recipeId)
            }
            let timestamp = now()
            let newVersionNumber = recipe.currentVersion + 1
            var version = PersonalRecipeVersionRecord(
                id: nil,
                recipeId: recipeId,
                version: newVersionNumber,
                ingredientsJSON: ingredientsJSON,
                outputGrams: outputGrams,
                outputWeightBasis: outputWeightBasis,
                note: note,
                createdAt: timestamp
            )
            try version.insert(db)

            recipe.displayName = trimmedName
            recipe.currentVersion = newVersionNumber
            recipe.updatedAt = timestamp
            try recipe.update(db)

            // 同名候选映射的展示名与默认份量跟随当前版本。
            if var mapping = try PersonalFoodRecord
                .filter(Column("recipe_id") == recipeId)
                .fetchOne(db) {
                mapping.displayName = trimmedName
                mapping.defaultGrams = outputGrams
                mapping.updatedAt = timestamp
                try mapping.update(db)
            }

            return RecipeWithVersion(recipe: recipe, version: version, recentMealCount: 0)
        }
    }

    func deleteRecipe(id: Int64) async throws {
        try await databaseManager.asyncWrite { db in
            try PersonalFoodRecord
                .filter(Column("recipe_id") == id)
                .deleteAll(db)
            try PersonalRecipeRecord.deleteOne(db, key: id)
        }
    }

    /// 历史餐次来源展示用：按引用串反查配方版本（目录缺失也返回版本快照）。
    func resolveProvenanceRef(_ ref: String) async throws -> (recipe: PersonalRecipeRecord, version: PersonalRecipeVersionRecord)? {
        let parts = ref.split(separator: ":")
        guard parts.count == 3, parts[0] == "recipe",
              let recipeId = Int64(parts[1]),
              parts[2].hasPrefix("v"),
              let versionNumber = Int(parts[2].dropFirst()) else {
            return nil
        }
        return try await databaseManager.asyncRead { db in
            guard let recipe = try PersonalRecipeRecord.fetchOne(db, key: recipeId) else {
                return nil
            }
            guard let version = try PersonalRecipeVersionRecord
                .filter(Column("recipe_id") == recipeId)
                .filter(Column("version") == versionNumber)
                .fetchOne(db) else {
                return nil
            }
            return (recipe, version)
        }
    }

    // MARK: - 校验

    private func validate(
        ingredients: [RecipeIngredient],
        outputGrams: Double?,
        outputWeightBasis: String?
    ) -> Bool {
        for ingredient in ingredients {
            switch ingredient.amountStatus {
            case .weighed, .estimated:
                guard let grams = ingredient.grams, FoodServingCalculator.validGrams(grams) else {
                    return false
                }
            case .notUsed, .unknown:
                break
            }
        }
        if let outputGrams {
            guard outputGrams.isFinite, outputGrams >= 0 else { return false }
        }
        if let outputWeightBasis, !["weighed", "estimated"].contains(outputWeightBasis) {
            return false
        }
        return true
    }
}
