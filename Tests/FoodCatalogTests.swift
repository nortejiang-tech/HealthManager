import XCTest
@testable import HealthManager

/// ADR-004 离线目录合同：资源可加载、种子条目与官方值一致、缺失语义不被写成 0、
/// 搜索与分类、份量换算（验收 A03/A04/A05/A06、A12）。
final class FoodCatalogTests: XCTestCase {

    private func makeStore() throws -> FoodCatalogStore {
        // 单测 host 是 App 本体，目录资源随 App bundle 打包。
        try FoodCatalogStore(bundle: .main)
    }

    func testCatalogLoadsFromAppBundle() throws {
        let store = try makeStore()
        XCTAssertGreaterThanOrEqual(store.catalog.entries.count, 41)
        XCTAssertEqual(store.catalog.schemaVersion, 1)
        XCTAssertEqual(store.catalog.source.agency, "MEXT")
        XCTAssertFalse(store.catalog.source.fileSha256.isEmpty)
    }

    func testSeedEntriesMatchVerifiedOfficialValues() throws {
        let store = try makeStore()

        // 方案附件逐条核对的三个种子（MEXT 八订增补2023）。
        let rice = try XCTUnwrap(store.entry(id: "mext-01088"))
        XCTAssertEqual(rice.nameOriginal, "こめ ［水稲めし］ 精白米 うるち米")
        XCTAssertEqual(rice.nutrients.kcal.value, 156)
        XCTAssertEqual(rice.nutrients.proteinG.value, 2.5)
        XCTAssertEqual(rice.nutrients.fatG.value, 0.3)
        XCTAssertEqual(rice.nutrients.carbsG.value, 37.1)
        XCTAssertEqual(rice.nutrients.sodiumMg.value, 1)
        XCTAssertEqual(rice.preparationState, .cooked)

        let egg = try XCTUnwrap(store.entry(id: "mext-12005"))
        XCTAssertEqual(egg.nutrients.kcal.value, 134)
        XCTAssertEqual(egg.nutrients.proteinG.value, 12.5)
        XCTAssertEqual(egg.nutrients.fatG.value, 10.4)
        XCTAssertEqual(egg.nutrients.carbsG.value, 0.3)
        XCTAssertEqual(egg.refusePercent, 11)

        let soymilk = try XCTUnwrap(store.entry(id: "mext-04052"))
        XCTAssertEqual(soymilk.nutrients.kcal.value, 43)
        XCTAssertEqual(soymilk.nutrients.proteinG.value, 3.6)
        XCTAssertEqual(soymilk.nutrients.fatG.value, 2.8)
        XCTAssertEqual(soymilk.nutrients.carbsG.value, 2.3)
    }

    func testMissingSemanticsArePreserved() throws {
        let store = try makeStore()

        // 黑咖啡（コーヒー 浸出液）脂质为 Tr（微量）——不得变成 0。
        let coffee = try XCTUnwrap(store.entry(id: "mext-16045"))
        XCTAssertEqual(coffee.nutrients.fatG.flag, .trace)
        XCTAssertNil(coffee.nutrients.fatG.value)

        // 全麦面包官方条目未标注推定值——flag 必须保留 measured。
        let wholeWheat = try XCTUnwrap(store.entry(id: "mext-01208"))
        XCTAssertEqual(wholeWheat.nutrients.proteinG.flag, .measured)

        // 全部条目的能量都已发布，且没有任何条目把 unmeasured 当 0。
        for entry in store.catalog.entries {
            XCTAssertNotEqual(entry.nutrients.kcal.flag, .unmeasured, entry.id)
            if let value = entry.nutrients.kcal.value {
                XCTAssertTrue(value.isFinite, entry.id)
            }
        }
    }

    func testEntryIdentityAndSourceFields() throws {
        let store = try makeStore()
        var ids = Set<String>()
        for entry in store.catalog.entries {
            XCTAssertTrue(ids.insert(entry.id).inserted, "重复 id: \(entry.id)")
            XCTAssertEqual(entry.source, "MEXT")
            XCTAssertTrue(entry.sourceUrl.hasPrefix("https://fooddb.mext.go.jp/"), entry.id)
            XCTAssertTrue(entry.sourceUrl.contains("_\(entry.foodNo)_"), entry.id)
            XCTAssertFalse(entry.nameOriginal.isEmpty, entry.id)
        }
    }

    func testSearchByChineseNameAliasAndOriginalName() throws {
        let store = try makeStore()

        XCTAssertEqual(store.search(query: "白煮蛋", category: nil).first?.id, "mext-12005")
        XCTAssertEqual(store.search(query: "煮鸡蛋", category: nil).first?.id, "mext-12005")
        XCTAssertTrue(store.search(query: "ゆで", category: nil).contains { $0.id == "mext-12005" })
        XCTAssertTrue(store.search(query: "豆浆", category: nil).contains { $0.id == "mext-04052" })
        // 空查询返回全部；无命中返回空。
        XCTAssertEqual(store.search(query: "", category: nil).count, store.catalog.entries.count)
        XCTAssertTrue(store.search(query: "不存在的食物xyz", category: nil).isEmpty)
    }

    func testCategoryFilter() throws {
        let store = try makeStore()
        let staples = store.search(query: "", category: .staple)
        XCTAssertFalse(staples.isEmpty)
        XCTAssertTrue(staples.allSatisfy { $0.category == .staple })
        // 分类筛选与搜索词叠加。
        XCTAssertTrue(store.search(query: "鸡蛋", category: .eggDairySoy).contains { $0.id == "mext-12005" })
        XCTAssertTrue(store.search(query: "鸡蛋", category: .staple).isEmpty)
    }

    // MARK: - 份量换算（A04/A06）

    func testServingScalingScalesByRatio() {
        let nutrients = FoodCatalogEntry.Nutrients(
            kcal: FoodCatalogNutrient(value: 156, flag: .measured),
            proteinG: FoodCatalogNutrient(value: 2.5, flag: .measured),
            fatG: FoodCatalogNutrient(value: 0.3, flag: .measured),
            carbsG: FoodCatalogNutrient(value: 37.1, flag: .measured),
            fiberG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            sodiumMg: FoodCatalogNutrient(value: nil, flag: .trace)
        )
        let scaled = FoodServingCalculator.scaled(nutrients, serving: 150)
        XCTAssertEqual(scaled?.kcal.value, 234)
        XCTAssertEqual(scaled?.proteinG.value, 3.75)
        XCTAssertEqual(scaled?.fatG.value, 0.45)
        XCTAssertEqual(scaled?.carbsG.value ?? 0, 55.65, accuracy: 0.0001)
        // 缺失语义不参与缩放、不变 0。
        XCTAssertNil(scaled?.fiberG.value)
        XCTAssertEqual(scaled?.fiberG.flag, .unmeasured)
        XCTAssertNil(scaled?.sodiumMg.value)
        XCTAssertEqual(scaled?.sodiumMg.flag, .trace)
    }

    func testServingScalingRejectsInvalidGrams() {
        let nutrient = FoodCatalogNutrient(value: 100, flag: .measured)
        XCTAssertNil(FoodServingCalculator.scaled(nutrient, serving: 0))
        XCTAssertNil(FoodServingCalculator.scaled(nutrient, serving: -50))
        XCTAssertNil(FoodServingCalculator.scaled(nutrient, serving: .infinity))
        XCTAssertNil(FoodServingCalculator.scaled(nutrient, serving: .nan))
        XCTAssertNil(FoodServingCalculator.scaled(FoodCatalogEntry.Nutrients(
            kcal: nutrient, proteinG: nutrient, fatG: nutrient, carbsG: nutrient,
            fiberG: nutrient, sodiumMg: nutrient
        ), serving: 0))
    }

    func testResourceErrorWhenDataIsInvalid() {
        XCTAssertThrowsError(try FoodCatalogStore(data: Data("not json".utf8)))

        // 结构合法但零条目 → 空包明确报错，不作为成功更新（A12）。
        let empty = #"{"schemaVersion":1,"source":{"agency":"T","title":"T","edition":"E","downloadUrl":"u","downloadedAt":"d","fileSha256":"s","termsOfUse":"t"},"entries":[]}"#
        XCTAssertThrowsError(try FoodCatalogStore(data: Data(empty.utf8))) { error in
            guard case FoodCatalogError.emptyCatalog = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
