import XCTest
import GRDB
@testable import HealthManager

/// 草稿工厂（A11/A12/A08）+ v9 迁移 + 备份 v2 往返（A13）。
final class PersonalFoodDraftAndBackupTests: XCTestCase {

    // MARK: - 草稿工厂

    func test_fromCatalogEntry_carriesProvenanceAndScalesWithGrams() {
        let store: FoodCatalogStore
        do {
            store = try FoodCatalogStore(bundle: .main)
        } catch {
            return XCTFail("目录资源必须随 App 打包：\(error)")
        }
        let rice = store.entry(id: "mext-01088")!
        let draft = MealItemDraft.fromCatalogEntry(rice, catalogVersion: store.catalog.source.edition)

        XCTAssertEqual(draft.provenanceKind, .nutritionDatabase)
        XCTAssertEqual(draft.provenanceRef, "mext-01088")
        XCTAssertEqual(draft.preparationState, .cooked)
        XCTAssertEqual(draft.baselineGrams, 100)
        XCTAssertFalse(draft.isUserEdited)

        // 100g → 150g 四指标按 1.5 倍（A04）。
        var scaled = draft
        scaled.gramsText = "150"
        XCTAssertEqual(scaled.calories ?? 0, 156 * 1.5, accuracy: 0.0001)
        XCTAssertEqual(scaled.protein ?? 0, 2.5 * 1.5, accuracy: 0.0001)

        // 非法克数不缩放也不崩溃（编辑器保存时校验拒绝）。
        var bad = draft
        bad.gramsText = "-3"
        XCTAssertEqual(bad.calories ?? 0, 156, accuracy: 0.0001)
    }

    func test_fromMatchedFood_prefillsDefaultGrams() {
        let entry = FoodCatalogEntry.fixture(id: "mext-06065", nameZh: "黄瓜·生")
        var food = PersonalFoodRecord(
            id: 7,
            kind: .catalog,
            displayName: "拍黄瓜",
            matchKeysJSON: PersonalFoodRecord.encodeMatchKeys(["黄瓜"]),
            catalogEntryId: entry.id,
            catalogVersion: "t",
            recipeId: nil,
            defaultGrams: 180,
            pinned: false,
            confirmedAt: 0,
            createdAt: 0,
            updatedAt: 0
        )
        let draft = MealItemDraft.fromMatchedFood(food, entry: entry, catalogVersion: "t", grams: food.defaultGrams)
        XCTAssertEqual(draft.name, "拍黄瓜")
        XCTAssertEqual(draft.gramsText, "180")
        XCTAssertEqual(draft.provenanceRef, "mext-06065")

        food.defaultGrams = nil
        let draftWithoutGrams = MealItemDraft.fromMatchedFood(food, entry: entry, catalogVersion: "t", grams: nil)
        XCTAssertEqual(draftWithoutGrams.gramsText, "")
    }

    func test_fromRecipe_producesRecipeCalculationDraft_andHandlesMissingOutput() {
        let egg = FoodCatalogEntry.fixture(id: "mext-12005", nameZh: "水煮全蛋", kcal: 134, protein: 12.5, fat: 10.4, carbs: 0.3)
        let soy = FoodCatalogEntry.fixture(id: "mext-04052", nameZh: "无调整豆乳", kcal: 43, protein: 3.6, fat: 2.8, carbs: 2.3)
        let ingredients = [
            RecipeIngredient(catalogEntryId: egg.id, catalogVersion: "t", nameZh: egg.nameZh,
                             basis: .per100g, preparationState: .cooked, grams: 150, amountStatus: .weighed),
            RecipeIngredient(catalogEntryId: soy.id, catalogVersion: "t", nameZh: soy.nameZh,
                             basis: .per100g, preparationState: .unknown, grams: 240, amountStatus: .estimated),
        ]
        var recipe = PersonalRecipeRecord(id: 42, displayName: "固定早餐", currentVersion: 2, createdAt: 0, updatedAt: 0)
        recipe.id = 42
        var version = PersonalRecipeVersionRecord(
            id: 9, recipeId: 42, version: 2,
            ingredientsJSON: (try? PersonalRecipeVersionRecord.encodeIngredients(ingredients)) ?? "[]",
            outputGrams: 390, outputWeightBasis: "estimated", note: nil, createdAt: 0
        )
        let draft = MealItemDraft.fromRecipe(
            recipe: recipe, version: version,
            entries: [egg.id: egg, soy.id: soy], grams: 390
        )
        XCTAssertEqual(draft.provenanceKind, .recipeCalculation)
        XCTAssertEqual(draft.provenanceRef, "recipe:42:v2")
        XCTAssertEqual(draft.preparationState, .cooked)
        // 每份 = 304.2 kcal（§4.1 复算示例），基准克数 = 成品重 390。
        XCTAssertEqual(draft.baselineCalories ?? 0, 304.2, accuracy: 0.001)
        XCTAssertEqual(draft.baselineGrams ?? 0, 390, accuracy: 0.001)
        XCTAssertEqual(draft.calories ?? 0, 304.2, accuracy: 0.001)

        // 缺成品重量：克数留空、总量照常（不得伪造每100g）。
        version.outputGrams = nil
        let pendingDraft = MealItemDraft.fromRecipe(
            recipe: recipe, version: version, entries: [egg.id: egg, soy.id: soy], grams: nil
        )
        XCTAssertNil(pendingDraft.baselineGrams)
        XCTAssertEqual(pendingDraft.gramsText, "")
        XCTAssertNotNil(pendingDraft.baselineCalories)

        // 目录条目缺失：营养按未知（不回退 0）。
        let missingEntryDraft = MealItemDraft.fromRecipe(
            recipe: recipe, version: version, entries: [:], grams: nil
        )
        XCTAssertNil(missingEntryDraft.baselineCalories)
    }

    // MARK: - v9 迁移

    private func makeMigratedPool(upTo migration: String? = nil) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-v9-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let migrator = Migrations.makeMigrator()
        if let migration {
            try migrator.migrate(pool, upTo: migration)
        } else {
            try migrator.migrate(pool)
        }
        return pool
    }

    func test_v9_preservesExistingMealItems_andAllowsRecipeCalculation() throws {
        let pool = try makeMigratedPool(upTo: "v8_round_dedup_raw_samples")

        // v8 状态下先造一餐一分项。
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_records (meal_type, eaten_at, created_at)
                    VALUES ('breakfast', 1000, 1000)
                    """
            )
            let mealId = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()")!
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, grams, preparation_state, calories_kcal,
                       protein_g, fat_g, carbs_g, provenance_kind, is_user_edited, created_at, updated_at)
                    VALUES (?, 0, '煮鸡蛋', 150, 'cooked', 201, 18.75, 15.6, 0.45, 'ai_estimate', 1, 1, 1)
                    """,
                arguments: [mealId]
            )
        }

        // 升到 v9。
        try Migrations.run(on: pool)

        // 既有行完整保留（id/数值/来源），且同餐重复 sort_order 仍被唯一索引拒绝。
        let count: Int = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM meal_items")!
        }
        XCTAssertEqual(count, 1)
        let preservedName: String = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM meal_items LIMIT 1")!
        }
        XCTAssertEqual(preservedName, "煮鸡蛋")
        let preservedKind: String = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT provenance_kind FROM meal_items LIMIT 1")!
        }
        XCTAssertEqual(preservedKind, "ai_estimate")
        let preservedGrams: Double = try pool.read { db in
            try Double.fetchOne(db, sql: "SELECT grams FROM meal_items LIMIT 1")!
        }
        XCTAssertEqual(preservedGrams, 150)

        let mealId: Int64 = try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT meal_id FROM meal_items LIMIT 1")!
        }
        XCTAssertThrowsError(try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, preparation_state, provenance_kind, is_user_edited, created_at, updated_at)
                    VALUES (?, 0, 'dup', 'cooked', 'manual', 0, 1, 1)
                    """,
                arguments: [mealId]
            )
        })

        // recipe_calculation 现在被接受；非法值仍被 CHECK 拒绝。
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, grams, preparation_state, provenance_kind,
                       provenance_ref, provenance_version, is_user_edited, created_at, updated_at)
                    VALUES (?, 1, '干豆腐卷大葱', 140, 'cooked', 'recipe_calculation', 'recipe:1:v1', 'v1', 0, 2, 2)
                    """,
                arguments: [mealId]
            )
        }
        XCTAssertThrowsError(try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, preparation_state, provenance_kind, is_user_edited, created_at, updated_at)
                    VALUES (?, 2, 'bad', 'cooked', 'nutrition_guess', 0, 3, 3)
                    """
            )
        })

        // 个人表存在。
        for table in ["personal_foods", "personal_recipes", "personal_recipe_versions", "ignored_candidates"] {
            let count = try pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM \(table)")!
            }
            XCTAssertEqual(count, 0, table)
        }
    }

    // MARK: - 备份 v2（A13）

    func test_backupV2_roundTripsPersonalData_andStillImportsV1() async throws {
        // 1. 源库：一餐普通记录 + 个人映射 + 配方 + 版本。
        let source = DatabaseManager.makeInMemoryForTesting()
        let mealStore = MealStore(databaseManager: source, now: { 500 })
        _ = try await mealStore.save(
            meal: MealRecord(
                id: nil, mealType: .lunch, eatenAt: 500,
                caloriesKcal: nil, proteinG: nil, fatG: nil, carbsG: nil,
                photoPath: nil, notes: nil, createdAt: 500, hkSyncId: nil
            ),
            items: []
        )
        let store = PersonalFoodStore(databaseManager: source, now: { 1_000 })
        let entry = FoodCatalogEntry.fixture(id: "mext-12005", nameZh: "水煮全蛋")
        _ = try await store.confirmCandidate(
            key: "煮鸡蛋", displayName: "煮鸡蛋", entry: entry, catalogVersion: "t-edition"
        )
        _ = try await store.createRecipe(
            name: "固定早餐",
            ingredients: [
                RecipeIngredient(catalogEntryId: entry.id, catalogVersion: "t-edition", nameZh: entry.nameZh,
                                 basis: .per100g, preparationState: .cooked, grams: 150, amountStatus: .weighed)
            ],
            outputGrams: 390, outputWeightBasis: "estimated", note: nil, matchKey: nil
        )

        // 2. 导出 → manifest v2 含新文件。
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v2-\(UUID().uuidString)", isDirectory: true)
        let manifest = try await BackupExporter(database: source).export(to: packageURL)
        XCTAssertEqual(manifest.formatVersion, 2)
        let fileNames = Set(manifest.files.map(\.file))
        XCTAssertTrue(fileNames.contains("personal_recipes.jsonl"))
        XCTAssertTrue(fileNames.contains("personal_recipe_versions.jsonl"))
        XCTAssertTrue(fileNames.contains("personal_foods.jsonl"))

        // 3. 新库导入 → 个人数据完整恢复（含 match_keys / 原料 JSON）。
        let target = DatabaseManager.makeInMemoryForTesting()
        let summary = try await BackupImporter(database: target).importPackage(from: packageURL)
        XCTAssertEqual(summary.importedCounts["personal_recipes"], 1)
        XCTAssertEqual(summary.importedCounts["personal_recipe_versions"], 1)
        XCTAssertEqual(summary.importedCounts["personal_foods"], 1)

        let restoredFoods = try await target.asyncRead { db in
            try PersonalFoodRecord.fetchAll(db)
        }
        XCTAssertEqual(restoredFoods.count, 1)
        XCTAssertEqual(restoredFoods.first?.matchKeys, ["煮鸡蛋"])

        // 4. 幂等重导。
        let again = try await BackupImporter(database: target).importPackage(from: packageURL)
        XCTAssertEqual(again.importedCounts["personal_foods"], 0)
        XCTAssertEqual(again.skippedCounts["personal_foods"], 1)

        // 5. v1 包（无新文件）仍可导入。
        let v1Manifest = BackupManifest(
            formatVersion: 1,
            appVersion: "0.5.1",
            exportedAt: 1,
            files: manifest.files.filter { !$0.file.hasPrefix("personal_") }
        )
        let v1Dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: v1Dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(v1Manifest).write(to: v1Dir.appendingPathComponent("manifest.json"))
        for entry in v1Manifest.files {
            let src = packageURL.appendingPathComponent(entry.file)
            let data = try Data(contentsOf: src)
            try data.write(to: v1Dir.appendingPathComponent(entry.file))
        }
        let v1Summary = try await BackupImporter(database: DatabaseManager.makeInMemoryForTesting())
            .importPackage(from: v1Dir)
        XCTAssertGreaterThan(v1Summary.importedCounts["meal_records"] ?? 0, 0, "v1 包的常规表照常导入")

        // 6. 更高版本（3）明确拒绝。
        let v3Dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: v3Dir, withIntermediateDirectories: true)
        let v3 = BackupManifest(formatVersion: 3, appVersion: "9.9", exportedAt: 1, files: [])
        try encoder.encode(v3).write(to: v3Dir.appendingPathComponent("manifest.json"))
        do {
            _ = try await BackupImporter(database: target).importPackage(from: v3Dir)
            XCTFail("formatVersion 3 必须被拒绝")
        } catch let error as BackupImportError {
            guard case .unsupportedFormatVersion(3) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
