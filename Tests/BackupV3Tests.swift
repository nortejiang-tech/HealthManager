import XCTest
import GRDB
@testable import HealthManager

/// 备份 v3 合同（验收 B1/D2/V1 的持久层）：
/// 官方身份/资料版本/参考表成员（含移除状态）随 v3 备份导出恢复，幂等、可离线；
/// v2/更早格式兼容导入；更高版本明确拒绝。
final class BackupV3Tests: XCTestCase {

    private func makeBundled() -> FoodCatalogStore {
        (try! FoodCatalogStore(bundle: .main))
    }

    func test_v3_roundTrip_preservesMembershipRemovedState_andSnapshots() async throws {
        let bundled = makeBundled()

        // 源库：种子 → 移除一条 → 导入一条 USDA 条目 → 建配方（带快照）。
        let source = DatabaseManager.makeInMemoryForTesting()
        let catalog = PersonalCatalogStore(databaseManager: source, now: { 1_000 })
        let foodStore = PersonalFoodStore(databaseManager: source, now: { 2_000 })
        let flags = FlagBox()
        try await catalog.seedIfNeeded(
            bundled: bundled,
            seedFlagReader: { flags.storage[$0] as Bool? },
            seedFlagWriter: { flags.storage[$0] = $1 }
        )
        let seededMembers = try await catalog.activeMembers()
        let rice = try XCTUnwrap(seededMembers.first { $0.entry.id == "mext-01088" })
        try await catalog.removeMember(id: rice.member.id!)

        let chocolate = try Self.usdaChocolateEntry()
        _ = try await catalog.importEntries([
            .init(entry: chocolate, displayName: "黑巧克力 70-85%", versionLabel: "FDC-Foundation-published-2019-04-01")
        ])

        let egg = bundled.entry(id: "mext-12005")!
        var eggIngredient = RecipeEditorView.ingredient(from: egg, versionLabel: bundled.catalog.source.edition)
        eggIngredient.grams = 100
        let recipe = try await foodStore.createRecipe(
            name: "测试配方",
            ingredients: [eggIngredient],
            outputGrams: 100,
            outputWeightBasis: "weighed",
            note: nil,
            matchKey: nil
        )
        XCTAssertNotNil(recipe.version.ingredients[0].nutritionSnapshot)

        // 导出 v3。
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v3-\(UUID().uuidString)", isDirectory: true)
        let manifest = try await BackupExporter(database: source).export(to: packageURL)
        XCTAssertEqual(manifest.formatVersion, 3)
        let fileNames = Set(manifest.files.map(\.file))
        XCTAssertTrue(fileNames.contains("official_foods.jsonl"))
        XCTAssertTrue(fileNames.contains("official_food_versions.jsonl"))
        XCTAssertTrue(fileNames.contains("personal_reference_entries.jsonl"))

        // 新库恢复。
        let target = DatabaseManager.makeInMemoryForTesting()
        let summary = try await BackupImporter(database: target).importPackage(from: packageURL)
        // 源库 = 41 条 MEXT 种子 + 1 条 USDA 导入；成员同样 42（含 1 条已移除）。
        XCTAssertEqual(summary.importedCounts["official_foods"], bundled.catalog.entries.count + 1)
        XCTAssertEqual(summary.importedCounts["personal_reference_entries"], bundled.catalog.entries.count + 1)

        // 移除状态持久（D2）：恢复后该成员仍处于移除状态，且不被种子复活。
        let targetCatalog = PersonalCatalogStore(databaseManager: target, now: { 5_000 })
        let targetFlags = FlagBox()
        // 模拟 settings 恢复：标记为 true（成员与移除状态以备份数据为准，不重播种子）。
        targetFlags.storage[PersonalCatalogStore.seedFlagKey] = true
        try await targetCatalog.seedIfNeeded(
            bundled: bundled,
            seedFlagReader: { key in targetFlags.storage[key] as Bool? },
            seedFlagWriter: { key, value in targetFlags.storage[key] = value }
        )
        let restoredActive = try await targetCatalog.activeMembers()
        XCTAssertFalse(restoredActive.contains { $0.entry.id == "mext-01088" }, "移除状态跨备份恢复保持")
        XCTAssertTrue(restoredActive.contains { $0.entry.id == "usda-\(chocolate.foodNo)" }, "导入的 USDA 条目随备份恢复")

        // 幂等重导。
        let again = try await BackupImporter(database: target).importPackage(from: packageURL)
        XCTAssertEqual(again.importedCounts["personal_reference_entries"], 0)

        // 成员选用版本与显示名恢复。
        let restoredUSDA = try XCTUnwrap(restoredActive.first { $0.entry.id == "usda-\(chocolate.foodNo)" })
        XCTAssertEqual(restoredUSDA.member.displayName, "黑巧克力 70-85%")
        XCTAssertEqual(try XCTUnwrap(restoredUSDA.version.nutrients).kcal.value, chocolate.nutrients.kcal.value)
    }

    func test_v3_export_then_v2StylePackage_importsCleanly() async throws {
        let source = DatabaseManager.makeInMemoryForTesting()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v3b-\(UUID().uuidString)", isDirectory: true)
        let manifest = try await BackupExporter(database: source).export(to: packageURL)

        // 手工构造 v2 包（剔除 v3 新文件，formatVersion=2）→ 新 App 仍兼容导入。
        let v2Files = manifest.files.filter {
            !["official_foods.jsonl", "official_food_versions.jsonl", "personal_reference_entries.jsonl"].contains($0.file)
        }
        let v2Manifest = BackupManifest(formatVersion: 2, appVersion: "0.6.0", exportedAt: 1, files: v2Files)
        let v2Dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-as-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(v2Manifest).write(to: v2Dir.appendingPathComponent("manifest.json"))
        for entry in v2Files {
            try Data(contentsOf: packageURL.appendingPathComponent(entry.file))
                .write(to: v2Dir.appendingPathComponent(entry.file))
        }
        let summary = try await BackupImporter(database: DatabaseManager.makeInMemoryForTesting())
            .importPackage(from: v2Dir)
        XCTAssertNotNil(summary)
    }

    func test_formatVersion4_rejected() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hm-backup-v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v4 = BackupManifest(formatVersion: 4, appVersion: "9.9", exportedAt: 1, files: [])
        try JSONEncoder().encode(v4).write(to: dir.appendingPathComponent("manifest.json"))
        do {
            _ = try await BackupImporter(database: DatabaseManager.makeInMemoryForTesting()).importPackage(from: dir)
            XCTFail("formatVersion 4 必须被拒绝")
        } catch let error as BackupImportError {
            guard case .unsupportedFormatVersion(4) = error else { return XCTFail("\(error)") }
        }
    }

    private static func usdaChocolateEntry() throws -> FoodCatalogEntry {
        let detail = try USDAApiClient.parseDetail(data: Data(Self.chocolateDetail.utf8))
        return try USDAFoodMapper.entry(from: detail)
    }

    private static let chocolateDetail = #"""
    {"fdcId":45164788,"description":"Dark chocolate, 70-85% cacao solids","dataType":"Foundation",
     "publicationDate":"2019-04-01",
     "foodNutrients":[
       {"nutrient":{"id":1008,"name":"Energy","unitName":"KCAL"},"amount":598.0,"unitName":"KCAL"},
       {"nutrient":{"id":1003,"name":"Protein","unitName":"G"},"amount":7.79,"unitName":"G"},
       {"nutrient":{"id":1004,"name":"Total lipid (fat)","unitName":"G"},"amount":42.63,"unitName":"G"},
       {"nutrient":{"id":1005,"name":"Carbohydrate, by difference","unitName":"G"},"amount":45.9,"unitName":"G"},
       {"nutrient":{"id":1079,"name":"Fiber, total dietary","unitName":"G"},"amount":10.9,"unitName":"G"},
       {"nutrient":{"id":1093,"name":"Sodium, Na","unitName":"MG"},"amount":20.0,"unitName":"MG"}
     ]}
    """#
}

final class FlagBox: @unchecked Sendable {
    var storage: [String: Bool] = [:]
}
