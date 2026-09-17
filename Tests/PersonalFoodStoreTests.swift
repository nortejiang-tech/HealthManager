import XCTest
import GRDB
@testable import HealthManager

/// 常吃统计与个人映射/配方存储合同（验收 A09/A10 + §5.1）。
final class PersonalFoodStoreTests: XCTestCase {

    private func makeStore(
        databaseManager: DatabaseManager? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) -> PersonalFoodStore {
        PersonalFoodStore(
            databaseManager: databaseManager ?? DatabaseManager.makeInMemoryForTesting(),
            now: now
        )
    }

    /// 本地自然日 → eaten_at（按当前日历的当天起点 + 偏移天数）。
    private func eatenAt(daysAgo: Int, hour: Int = 8, calendar: Calendar = .current) -> Int64 {
        let dayStart = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: dayStart)!
        let withHour = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        return Int64(withHour.timeIntervalSince1970)
    }

    private func insertMeal(
        _ dbManager: DatabaseManager,
        eatenAt: Int64,
        items: [(name: String, grams: Double?, kind: MealItemRecord.ProvenanceKind)]
    ) async throws -> Int64 {
        let meal = MealRecord(
            id: nil,
            mealType: .breakfast,
            eatenAt: eatenAt,
            caloriesKcal: nil,
            proteinG: nil,
            fatG: nil,
            carbsG: nil,
            photoPath: nil,
            notes: nil,
            createdAt: eatenAt,
            hkSyncId: nil
        )
        let snapshot = try await dbManager.insertForTesting(meal: meal, items: items)
        return snapshot.meal.id!
    }

    // MARK: 常吃统计（A09）

    func test_frequentSummary_deduplicatesPerMeal_andHonorsWindow() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        // 30 天窗口内：两餐都含煮鸡蛋 → 2 餐（一餐两条同名只计一次）。
        _ = try await insertMeal(db, eatenAt: eatenAt(daysAgo: 1), items: [
            (name: "煮鸡蛋", grams: 150, kind: .aiEstimate),
            (name: "白煮蛋", grams: 150, kind: .aiEstimate),
        ])
        _ = try await insertMeal(db, eatenAt: eatenAt(daysAgo: 3), items: [
            (name: "煮鸡蛋", grams: 150, kind: .aiEstimate),
        ])
        // 窗口外：40 天前。
        _ = try await insertMeal(db, eatenAt: eatenAt(daysAgo: 40), items: [
            (name: "煮鸡蛋", grams: 150, kind: .aiEstimate),
        ])

        let store = makeStore(databaseManager: db)
        let recent = try await store.loadFrequentPage(windowDays: 30)
        let eggRecent = recent.pendingCandidates.first { $0.key == MealItemIdentity.canonicalName("煮鸡蛋") }
        // 煮鸡蛋/白煮蛋同为 canonicalName 归并（去空白+小写不同——中文不归并！）
        // 注意：canonicalName 不做语义归并，两键分开；此处验证窗口与去重即可。
        XCTAssertNotNil(eggRecent)
        XCTAssertEqual(eggRecent?.mealCount, 2)

        let all = try await store.loadFrequentPage(windowDays: nil)
        let eggAll = all.pendingCandidates.first { $0.key == MealItemIdentity.canonicalName("煮鸡蛋") }
        XCTAssertEqual(eggAll?.mealCount, 3, "全部历史还应包含 40 天前那一餐")
    }

    func test_summarize_countsDistinctMealOnce_perKey() {
        let facts: [FrequentFoodsQuery.MealFacts] = [
            .init(mealId: 1, eatenAt: 100, items: [
                .init(name: "煮鸡蛋", grams: 150),
                .init(name: "煮鸡蛋", grams: 150),
            ]),
            .init(mealId: 2, eatenAt: 200, items: [
                .init(name: "煮鸡蛋", grams: 150),
            ]),
        ]
        let summaries = FrequentFoodsQuery.summarize(mealFacts: facts)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.mealCount, 2, "同餐重复同名只计一餐")
        XCTAssertEqual(summaries.first?.commonGrams, 150)
        XCTAssertEqual(summaries.first?.lastEatenAt, 200)
    }

    // MARK: 候选确认 / 忽略（A09）

    func test_confirmAndIgnore_flowsThroughPendingList() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        _ = try await insertMeal(db, eatenAt: eatenAt(daysAgo: 1), items: [
            (name: "无糖豆浆", grams: 240, kind: .aiEstimate),
            (name: "煮鸡蛋", grams: 150, kind: .aiEstimate),
        ])

        let store = makeStore(databaseManager: db)
        let entry = FoodCatalogEntry.fixture(id: "mext-12005", nameZh: "水煮全蛋")

        // 确认煮鸡蛋 → 从候选消失，出现在已匹配。
        _ = try await store.confirmCandidate(
            key: MealItemIdentity.canonicalName("煮鸡蛋"),
            displayName: "煮鸡蛋",
            entry: entry,
            catalogVersion: "test-edition"
        )
        var page = try await store.loadFrequentPage(windowDays: 30)
        XCTAssertFalse(page.pendingCandidates.contains { $0.displayName == "煮鸡蛋" })
        XCTAssertEqual(page.matchedFoods.first?.food.catalogEntryId, "mext-12005")
        XCTAssertEqual(page.matchedFoods.first?.recentMealCount, 1)

        // 忽略无糖豆浆 → 从候选消失且不重现。
        try await store.ignoreCandidate(key: MealItemIdentity.canonicalName("无糖豆浆"))
        try await store.ignoreCandidate(key: MealItemIdentity.canonicalName("无糖豆浆"))
        page = try await store.loadFrequentPage(windowDays: 30)
        XCTAssertFalse(page.pendingCandidates.contains { $0.displayName == "无糖豆浆" })
    }

    func test_pinnedFoodSortsFirst_andDefaultGramsPersist() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        _ = try await insertMeal(db, eatenAt: eatenAt(daysAgo: 1), items: [
            (name: "黄瓜", grams: 200, kind: .aiEstimate),
            (name: "西红柿", grams: 100, kind: .aiEstimate),
            (name: "西红柿", grams: 100, kind: .aiEstimate),
        ])

        let store = makeStore(databaseManager: db)
        let cucumber = FoodCatalogEntry.fixture(id: "mext-06065", nameZh: "黄瓜·生")
        let tomato = FoodCatalogEntry.fixture(id: "mext-06182", nameZh: "番茄·生")
        _ = try await store.confirmCandidate(
            key: MealItemIdentity.canonicalName("黄瓜"), displayName: "黄瓜", entry: cucumber, catalogVersion: "t"
        )
        _ = try await store.confirmCandidate(
            key: MealItemIdentity.canonicalName("西红柿"), displayName: "西红柿", entry: tomato, catalogVersion: "t"
        )

        // 未置顶时按近30天餐数排序：西红柿(2) > 黄瓜(1)。
        var page = try await store.loadFrequentPage(windowDays: 30)
        XCTAssertEqual(page.matchedFoods.first?.food.displayName, "西红柿")

        // 置顶黄瓜 → 排最前；默认份量可写。
        let cucumberFood = try XCTUnwrap(page.matchedFoods.first { $0.food.displayName == "黄瓜" }.map(\.food))
        try await store.setPinned(foodId: cucumberFood.id!, pinned: true)
        try await store.setDefaultGrams(foodId: cucumberFood.id!, grams: 180)

        page = try await store.loadFrequentPage(windowDays: 30)
        XCTAssertEqual(page.matchedFoods.first?.food.displayName, "黄瓜")
        XCTAssertEqual(page.matchedFoods.first?.food.defaultGrams, 180)
        XCTAssertEqual(page.matchedFoods.first?.recentCommonGrams, 200, "常用克数来自记录统计")
    }

    // MARK: 配方版本（A10 + §2.4 不可变版本）

    func test_recipeRevisionCreatesNewVersion_andOldVersionRemains() async throws {
        let store = makeStore()
        let egg = FoodCatalogEntry.fixture(id: "mext-12005", nameZh: "水煮全蛋")
        let soy = FoodCatalogEntry.fixture(id: "mext-04052", nameZh: "无调整豆乳")
        let ingredients = [
            RecipeIngredient(
                catalogEntryId: egg.id, catalogVersion: "t", nameZh: egg.nameZh,
                basis: .per100g, preparationState: .cooked, grams: 150, amountStatus: .weighed
            ),
            RecipeIngredient(
                catalogEntryId: soy.id, catalogVersion: "t", nameZh: soy.nameZh,
                basis: .per100g, preparationState: .unknown, grams: 240, amountStatus: .estimated
            ),
        ]

        let created = try await store.createRecipe(
            name: "固定早餐",
            ingredients: ingredients,
            outputGrams: 390,
            outputWeightBasis: "estimated",
            note: nil,
            matchKey: MealItemIdentity.canonicalName("固定早餐")
        )
        XCTAssertEqual(created.version.version, 1)
        XCTAssertEqual(created.recipe.currentVersion, 1)

        // 修订：豆浆改 300g → 生成 v2。
        let revised = try await store.updateRecipe(
            recipeId: created.recipe.id!,
            name: "固定早餐",
            ingredients: [
                ingredients[0],
                RecipeIngredient(
                    catalogEntryId: soy.id, catalogVersion: "t", nameZh: soy.nameZh,
                    basis: .per100g, preparationState: .unknown, grams: 300, amountStatus: .estimated
                ),
            ],
            outputGrams: 450,
            outputWeightBasis: "estimated",
            note: "加了半杯豆浆"
        )
        XCTAssertEqual(revised.version.version, 2)
        XCTAssertEqual(revised.version.ingredients.first { $0.catalogEntryId == soy.id }?.grams, 300)

        // 旧版本仍可按引用解析（历史餐次引用旧快照不被覆盖，A10）。
        let oldRef = PersonalFoodStore.provenanceRef(recipeId: created.recipe.id!, version: 1)
        let resolved = try await store.resolveProvenanceRef(oldRef)
        XCTAssertEqual(resolved?.version.version, 1)
        XCTAssertEqual(resolved?.version.ingredients.first { $0.catalogEntryId == soy.id }?.grams, 240)
    }

    func test_recipeWithUnknownAmount_validates() async throws {
        let store = makeStore()
        let oil = FoodCatalogEntry.fixture(id: "mext-14008", nameZh: "菜籽油")
        let unknown = RecipeIngredient(
            catalogEntryId: oil.id, catalogVersion: "t", nameZh: oil.nameZh,
            basis: .per100g, preparationState: .unknown, grams: nil, amountStatus: .unknown
        )
        // 未知用量允许保存（不按 0），草稿待补。
        let created = try await store.createRecipe(
            name: "清炒", ingredients: [unknown], outputGrams: nil,
            outputWeightBasis: nil, note: nil, matchKey: nil
        )
        XCTAssertNil(created.version.outputGrams)

        // 称量状态但克数无效 → 拒绝。
        let badWeighed = RecipeIngredient(
            catalogEntryId: oil.id, catalogVersion: "t", nameZh: oil.nameZh,
            basis: .per100g, preparationState: .unknown, grams: nil, amountStatus: .weighed
        )
        do {
            _ = try await store.createRecipe(
                name: "清炒2", ingredients: [badWeighed], outputGrams: nil,
                outputWeightBasis: nil, note: nil, matchKey: nil
            )
            XCTFail("称量状态缺少有效克数时必须拒绝保存")
        } catch {
            // 预期抛出 StoreError.invalidInput。
        }
    }

    func test_deleteRecipe_removesMappingButKeepsHistoricalSnapshotRow() async throws {
        let store = makeStore()
        let created = try await store.createRecipe(
            name: "干豆腐卷大葱", ingredients: [], outputGrams: nil,
            outputWeightBasis: nil, note: nil, matchKey: nil
        )
        try await store.deleteRecipe(id: created.recipe.id!)
        let resolved = try await store.resolveProvenanceRef(
            PersonalFoodStore.provenanceRef(recipeId: created.recipe.id!, version: 1)
        )
        XCTAssertNil(resolved, "配方删除后不再解析；已保存餐次的 meal_items 快照独立存在，不受影响")
    }
}

extension FoodCatalogEntry {
    /// 测试用最小条目。
    static func fixture(
        id: String,
        nameZh: String,
        kcal: Double = 100,
        protein: Double = 10,
        fat: Double = 5,
        carbs: Double = 10
    ) -> FoodCatalogEntry {
        func n(_ v: Double) -> FoodCatalogNutrient { FoodCatalogNutrient(value: v, flag: .measured) }
        return FoodCatalogEntry(
            id: id,
            source: "TEST",
            foodNo: id,
            foodGroup: "00",
            nameZh: nameZh,
            nameOriginal: nameZh,
            aliases: [],
            category: .vegetableFruit,
            preparationState: .cooked,
            basis: .per100g,
            refusePercent: nil,
            nutrients: FoodCatalogEntry.Nutrients(
                kcal: n(kcal), proteinG: n(protein), fatG: n(fat), carbsG: n(carbs),
                fiberG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
                sodiumMg: FoodCatalogNutrient(value: nil, flag: .unmeasured)
            ),
            sourceUrl: "https://example.com/\(id)",
            note: ""
        )
    }
}

extension DatabaseManager {
    /// 测试辅助：直接写入一餐（绕过协调器，不触发 HealthKit）。
    fileprivate func mealStoreForTesting() -> MealStore {
        MealStore(databaseManager: self)
    }

    fileprivate func insertForTesting(
        meal: MealRecord,
        items: [(name: String, grams: Double?, kind: MealItemRecord.ProvenanceKind)]
    ) async throws -> MealStore.Snapshot {
        try await mealStoreForTesting().save(
            meal: meal,
            items: items.map {
                MealStore.ItemInput(
                    name: $0.name,
                    grams: $0.grams,
                    preparationState: .cooked,
                    caloriesKcal: 100,
                    proteinG: 10,
                    fatG: 5,
                    carbsG: 10,
                    provenanceKind: $0.kind
                )
            }
        )
    }
}
