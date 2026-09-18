import XCTest
@testable import HealthManager

/// USDA 适配器合同（S3/S4/N1）与统一搜索（S1/S2/S5 排序层）。
final class USDAServiceTests: XCTestCase {

    // MARK: - 解析与映射（S3/N1）

    private let searchFixture = #"""
    {"totalHits":2,"foods":[
      {"fdcId":45164788,"description":"Dark chocolate, 70-85% cacao solids","dataType":"Foundation","brandOwner":null},
      {"fdcId":1234567,"description":"Chocolate chip cookie","dataType":"Branded","brandOwner":"ACME"}
    ]}
    """#

    private let detailFixture = #"""
    {"fdcId":45164788,"description":"Dark chocolate, 70-85% cacao solids","dataType":"Foundation",
     "publicationDate":"2019-04-01",
     "foodNutrients":[
       {"nutrient":{"id":1008,"number":"208","name":"Energy","unitName":"KCAL"},"amount":598.0,"unitName":"KCAL"},
       {"nutrient":{"id":1003,"number":"203","name":"Protein","unitName":"G"},"amount":7.79,"unitName":"G"},
       {"nutrient":{"id":1004,"number":"204","name":"Total lipid (fat)","unitName":"G"},"amount":42.63,"unitName":"G"},
       {"nutrient":{"id":1005,"number":"205","name":"Carbohydrate, by difference","unitName":"G"},"amount":45.9,"unitName":"G"},
       {"nutrient":{"id":1079,"number":"291","name":"Fiber, total dietary","unitName":"G"},"amount":10.9,"unitName":"G"},
       {"nutrient":{"id":1093,"number":"307","name":"Sodium, Na","unitName":"MG"},"amount":20.0,"unitName":"MG"},
       {"nutrient":{"id":1087,"number":"306","name":"Calcium, Ca","unitName":"MG"},"amount":null,"unitName":"MG"}
     ]}
    """#

    func test_parseSearch_extractsHits() throws {
        let hits = try USDAApiClient.parseSearch(data: Data(searchFixture.utf8))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].fdcId, 45164788)
        XCTAssertEqual(hits[0].dataType, "Foundation")
        XCTAssertEqual(hits[1].brandOwner, "ACME")
    }

    func test_parseDetail_mapsOfficialNutrientIDs_andPreservesSemantics() throws {
        let detail = try USDAApiClient.parseDetail(data: Data(detailFixture.utf8))
        XCTAssertEqual(detail.mapped.kcal?.value, 598)
        XCTAssertEqual(detail.mapped.energyRule, "energy-1008-kcal")
        XCTAssertEqual(detail.mapped.proteinG?.value, 7.79)
        XCTAssertEqual(detail.mapped.sodiumMg?.value, 20)

        let entry = try USDAFoodMapper.entry(from: detail)
        XCTAssertEqual(entry.id, "usda-45164788")
        XCTAssertEqual(entry.source, "USDA")
        XCTAssertEqual(entry.basis, .per100g)
        XCTAssertEqual(entry.category, .sweetsSnacks, "chocolate 关键词归零食甜食")
        XCTAssertTrue(entry.note.contains("energy-1008-kcal"), "能量口径规则随条目留存")
        XCTAssertEqual(USDAFoodMapper.versionLabel(for: detail), "FDC-Foundation-published-2019-04-01")
    }

    func test_energyFallsBackToKJ_withRuleRecorded() throws {
        let json = #"""
        {"fdcId":7,"description":"X","dataType":"Foundation","publicationDate":null,
         "foodNutrients":[{"nutrient":{"id":1062,"name":"Energy","unitName":"kJ"},"amount":2500.0,"unitName":"kJ"}]}
        """#
        let detail = try USDAApiClient.parseDetail(data: Data(json.utf8))
        let kcal = try XCTUnwrap(detail.mapped.kcal)
        XCTAssertEqual(kcal.value ?? 0, 2500.0 / 4.184, accuracy: 0.001)
        XCTAssertEqual(kcal.flag, .estimated, "kJ 换算值标注推定")
        XCTAssertEqual(detail.mapped.energyRule, "energy-1062-kj-divided-4.184")
    }

    func test_missingNutrient_isUnmeasured_notZero() throws {
        let json = #"""
        {"fdcId":8,"description":"Y","dataType":"SR Legacy","publicationDate":null,
         "foodNutrients":[{"nutrient":{"id":1003,"name":"Protein","unitName":"G"},"amount":2.0,"unitName":"G"}]}
        """#
        let detail = try USDAApiClient.parseDetail(data: Data(json.utf8))
        XCTAssertNil(detail.mapped.kcal, "无能量 → 不伪造")
        XCTAssertNil(detail.mapped.fatG?.value)
        XCTAssertEqual(detail.mapped.fatG?.flag, .unmeasured)
        XCTAssertEqual(detail.mapped.proteinG?.value, 2.0)
    }

    func test_brandedDataRejected_perServingIsNotPer100g() {
        let json = #"""
        {"fdcId":9,"description":"Branded bar","dataType":"Branded","publicationDate":null,
         "foodNutrients":[{"nutrient":{"id":1008,"name":"Energy","unitName":"KCAL"},"amount":120.0,"unitName":"KCAL"}]}
        """#
        let detail = try? USDAApiClient.parseDetail(data: Data(json.utf8))
        let entry = detail.flatMap { try? USDAFoodMapper.entry(from: $0) }
        XCTAssertNil(entry, "每份标签不得当作每 100 g（N1/§4.3）")
    }

    // MARK: - 客户端错误状态（S4）

    private func makeClient(status: Int, retryAfter: String? = nil) -> USDAApiClient {
        USDAApiClient { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.nal.usda.gov")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: retryAfter.map { ["Retry-After": $0] }
            )!
            return (Data("{}".utf8), response)
        }
    }

    func test_errorStates_areDistinct() async {
        let originalKey = USDAKeyStore.apiKey
        USDAKeyStore.setApiKey("test-key-for-error-mapping")
        defer { USDAKeyStore.setApiKey(originalKey) }
        do { _ = try await makeClient(status: 401).search(query: "x")
            XCTFail("should throw")
        } catch let error as USDAServiceError {
            XCTAssertEqual(error, .unauthorized)
        } catch { XCTFail("\(error)") }

        do { _ = try await makeClient(status: 429, retryAfter: "30").search(query: "x")
            XCTFail("should throw")
        } catch let error as USDAServiceError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 30))
        } catch { XCTFail("\(error)") }

        do { _ = try await makeClient(status: 500).search(query: "x")
            XCTFail("should throw")
        } catch let error as USDAServiceError {
            guard case .badResponse = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func test_unconfiguredKey_throwsNotConfigured_beforeNetwork() async {
        let original = USDAKeyStore.apiKey
        USDAKeyStore.setApiKey("")
        defer { USDAKeyStore.setApiKey(original) }
        do {
            _ = try await makeClient(status: 200).search(query: "x")
            XCTFail("should throw")
        } catch let error as USDAServiceError {
            XCTAssertEqual(error, .notConfigured)
        } catch { XCTFail("\(error)") }
    }

    // MARK: - 统一搜索排序（S1/S2）

    private func makeService() -> FoodSearchService {
        FoodSearchService(
            bundled: (try! FoodCatalogStore(bundle: .main)),
            personalCatalog: PersonalCatalogStore(databaseManager: DatabaseManager.makeInMemoryForTesting())
        )
    }

    private func entry(_ id: String, zh: String, original: String = "", aliases: [String] = []) -> FoodCatalogEntry {
        func n(_ v: Double?) -> FoodCatalogNutrient {
            FoodCatalogNutrient(value: v, flag: v == nil ? .unmeasured : .measured)
        }
        return FoodCatalogEntry(
            id: id, source: "MEXT", foodNo: id, foodGroup: "0",
            nameZh: zh, nameOriginal: original, aliases: aliases,
            category: .vegetableFruit, preparationState: .raw, basis: .per100g,
            refusePercent: nil,
            nutrients: FoodCatalogEntry.Nutrients(
                kcal: n(1), proteinG: n(1), fatG: n(1), carbsG: n(1),
                fiberG: n(nil), sodiumMg: n(nil)
            ),
            sourceUrl: "https://example.com/\(id)", note: ""
        )
    }

    func test_qualifierMismatch_demotesCookieForm() {
        let dark = entry("usda-1", zh: "黑巧克力（70–85% 可可）", aliases: ["dark chocolate"])
        let cookie = entry("usda-2", zh: "黑巧克力饼干", aliases: ["chocolate cookie"])
        let ranked = FoodSearchService.rank(entries: [dark, cookie], query: "黑巧克力")
        XCTAssertEqual(ranked.first?.0.id, "usda-1", "普通黑巧克力排在饼干之前（S2）")
        XCTAssertEqual(ranked.first?.1, .strong)
        XCTAssertEqual(ranked.last?.1, .possible, "形态词（饼干）在查询之外 → 可能匹配")
    }

    func test_typo_yieldsPossibleMatch() {
        let soy = entry("mext-04052", zh: "无调整豆乳", aliases: ["豆浆", "无糖豆浆"])
        let ranked = FoodSearchService.rank(entries: [soy], query: "无糖豆乳 ")
        XCTAssertFalse(ranked.isEmpty, "近似词仍可发现（S1）")
    }

    func test_englishAlias_found() {
        let dark = entry("usda-1", zh: "黑巧克力（70–85%）", aliases: ["dark chocolate"])
        let ranked = FoodSearchService.rank(entries: [dark], query: "dark chocolate")
        XCTAssertEqual(ranked.first?.1, .exact)
    }
}

/// 推测配方合同（R1~R4 校验层）。
final class RecipeSuggestionServiceTests: XCTestCase {

    private let pool: [FoodCatalogEntry] = [
        Tests_RecipeFixtures.entry("mext-06026", zh: "大葱"),
        Tests_RecipeFixtures.entry("mext-14008", zh: "菜籽油"),
        Tests_RecipeFixtures.entry("mext-17012", zh: "食盐"),
    ]

    private func makeService(raw: @escaping @Sendable (String) -> String) -> RecipeSuggestionService {
        RecipeSuggestionService { _, _ in raw("stub") }
    }

    func test_validSuggestion_parsesWithEstimatedStatus() async throws {
        let service = makeService { _ in
            #"""
            {"ingredients":[
              {"id":"mext-06026","grams":30,"status":"estimated"},
              {"id":"mext-14008","grams":8,"status":"estimated"}],
             "pending":["蘸酱"],
             "output_grams":120,
             "rationale":"按常见家常做法推测。"}
            """#
        }
        let suggestion = try await service.suggest(dishName: "干豆腐卷大葱", candidates: pool, historyContext: "")
        XCTAssertEqual(suggestion.ingredients.count, 2)
        XCTAssertEqual(suggestion.ingredients[0].amountStatus, .estimated, "模型建议最高为估计")
        XCTAssertNotNil(suggestion.ingredients[0].nutritionSnapshot, "候选池条目带快照")
        XCTAssertEqual(suggestion.pendingNames, ["蘸酱"])
        XCTAssertEqual(suggestion.outputGrams, 120)
    }

    func test_fabricatedID_rejected() async {
        let service = makeService { _ in
            #"{"ingredients":[{"id":"usda-999999","grams":10,"status":"estimated"}],"pending":[],"output_grams":null}"#
        }
        do {
            _ = try await service.suggest(dishName: "x", candidates: pool, historyContext: "")
            XCTFail("编造 ID 必须被拒（R3）")
        } catch let error as RecipeSuggestionService.SuggestionError {
            guard case .invalidResponse(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("候选池之外"))
        } catch { XCTFail("\(error)") }
    }

    func test_negativeGrams_andWeighedClaim_rejected() async {
        let negative = makeService { _ in
            #"{"ingredients":[{"id":"mext-06026","grams":-5,"status":"estimated"}],"pending":[]}"#
        }
        await XCTAssertThrowsErrorAsync(try await negative.suggest(dishName: "x", candidates: pool, historyContext: ""))

        let weighed = makeService { _ in
            #"{"ingredients":[{"id":"mext-06026","grams":10,"status":"weighed"}],"pending":[]}"#
        }
        await XCTAssertThrowsErrorAsync(try await weighed.suggest(dishName: "x", candidates: pool, historyContext: ""),
                                        "模型无权宣称已称量")
    }

    func test_jsonFence_extracted() {
        let fenced = "```json\n{\"a\":1}\n```"
        XCTAssertEqual(RecipeSuggestionService.extractJSONObject(from: fenced), "{\"a\":1}")
    }
}

/// 方案 §8.1 计算示例：A 100kcal/100g ×200g + B 900×10 = 290；÷250g → 116；÷300g → 96.7。
final class RecipeCalculationExampleTests: XCTestCase {

    func test_documentedExample_matches() {
        func ingredient(kcal: Double, grams: Double) -> RecipeCalculator.IngredientInput {
            RecipeCalculator.IngredientInput(
                per100: FoodCatalogEntry.Nutrients(
                    kcal: FoodCatalogNutrient(value: kcal, flag: .measured),
                    proteinG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
                    fatG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
                    carbsG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
                    fiberG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
                    sodiumMg: FoodCatalogNutrient(value: nil, flag: .unmeasured)
                ),
                grams: grams,
                status: .weighed
            )
        }
        let a = ingredient(kcal: 100, grams: 200)
        let b = ingredient(kcal: 900, grams: 10)

        let at250 = RecipeCalculator.calculate(ingredients: [a, b], outputGrams: 250)
        XCTAssertEqual(at250.totals.caloriesKcal ?? 0, 290, accuracy: 0.001)
        XCTAssertEqual(at250.per100?.caloriesKcal ?? 0, 116, accuracy: 0.001)

        let at300 = RecipeCalculator.calculate(ingredients: [a, b], outputGrams: 300)
        XCTAssertEqual(at300.per100?.caloriesKcal ?? 0, 290.0 * 100 / 300, accuracy: 0.01)

        // 存在未知原料时不能仍把 290 当完整总量（方案明确要求）。
        let unknownNutrients = FoodCatalogEntry.Nutrients(
            kcal: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            proteinG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fatG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            carbsG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fiberG: FoodCatalogNutrient(value: nil, flag: .unmeasured),
            sodiumMg: FoodCatalogNutrient(value: nil, flag: .unmeasured)
        )
        let unknown = RecipeCalculator.IngredientInput(per100: unknownNutrients, grams: nil, status: .unknown)
        let withUnknown = RecipeCalculator.calculate(ingredients: [a, b, unknown], outputGrams: 250)
        XCTAssertNil(withUnknown.totals.caloriesKcal)
        XCTAssertNil(withUnknown.per100)
    }
}

enum Tests_RecipeFixtures {
    static func entry(_ id: String, zh: String) -> FoodCatalogEntry {
        func n(_ v: Double?) -> FoodCatalogNutrient {
            FoodCatalogNutrient(value: v, flag: v == nil ? .unmeasured : .measured)
        }
        return FoodCatalogEntry(
            id: id, source: "MEXT", foodNo: id, foodGroup: "0",
            nameZh: zh, nameOriginal: zh, aliases: [],
            category: .vegetableFruit, preparationState: .raw, basis: .per100g,
            refusePercent: nil,
            nutrients: FoodCatalogEntry.Nutrients(
                kcal: n(50), proteinG: n(1), fatG: n(1), carbsG: n(5),
                fiberG: n(nil), sodiumMg: n(nil)
            ),
            sourceUrl: "https://example.com/\(id)", note: ""
        )
    }
}

extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                     _ message: String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected error. \(message)", file: file, line: line)
        } catch {
            // expected
        }
    }
}
