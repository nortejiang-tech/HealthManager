import XCTest
import UIKit
@testable import HealthManager

final class MealNutritionAnalyzerTests: XCTestCase {

    // MARK: - v6 items schema (primary path)

    func test_parse_itemsSchema_singleItem() throws {
        let raw = """
        {"items": [{"name": "米饭", "grams": 200, "calories_kcal": 260, "protein_g": 5, "fat_g": 0.6, "carbs_g": 58}], "confidence": "medium", "note": ""}
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.count, 1)
        XCTAssertEqual(est.items.first?.name, "米饭")
        XCTAssertEqual(est.items.first?.grams, 200)
        XCTAssertEqual(est.items.first?.calories_kcal, 260)
        XCTAssertEqual(est.confidence, "medium")
        XCTAssertEqual(est.totalCalories, 260)
        XCTAssertEqual(est.totalProtein, 5)
    }

    func test_parse_itemsSchema_multipleDishes() throws {
        let raw = """
        {"items": [
          {"name": "米饭", "grams": 200, "calories_kcal": 260, "protein_g": 5, "fat_g": 0.6, "carbs_g": 58},
          {"name": "炒青菜", "grams": 150, "calories_kcal": 60, "protein_g": 3, "fat_g": 4, "carbs_g": 4},
          {"name": "煎蛋", "grams": 50, "calories_kcal": 90, "protein_g": 6, "fat_g": 7, "carbs_g": 0.5}
        ], "confidence": "medium"}
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.count, 3)
        XCTAssertEqual(est.totalCalories, 410)
        XCTAssertEqual(est.totalProtein, 14)
        XCTAssertEqual(est.totalCarbs, 62.5)
        XCTAssertNil(est.note)
    }

    func test_parse_itemsSchema_emptyArray() throws {
        // Model decided photo isn't food.
        let raw = "{\"items\": [], \"confidence\": \"low\", \"note\": \"图片不像食物\"}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertTrue(est.items.isEmpty)
        XCTAssertEqual(est.totalCalories, 0)
        XCTAssertEqual(est.note, "图片不像食物")
    }

    // MARK: - v5 legacy single-dish schema (backward compat — wraps as one item)

    func test_parse_plainJSON_legacy() throws {
        let raw = """
        {"name": "番茄炒蛋", "calories_kcal": 320, "protein_g": 14, "fat_g": 22, "carbs_g": 10, "confidence": "medium", "note": "估算保守"}
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.count, 1)
        XCTAssertEqual(est.items.first?.name, "番茄炒蛋")
        XCTAssertEqual(est.items.first?.calories_kcal, 320)
        XCTAssertEqual(est.items.first?.protein_g, 14)
        XCTAssertEqual(est.confidence, "medium")
        XCTAssertEqual(est.note, "估算保守")
    }

    func test_parse_strippedFences_json_legacy() throws {
        let raw = """
        ```json
        {"name": "拉面", "calories_kcal": 550, "protein_g": 22, "fat_g": 18, "carbs_g": 70, "confidence": "high", "note": null}
        ```
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "拉面")
        XCTAssertEqual(est.confidence, "high")
        XCTAssertNil(est.note)
    }

    func test_parse_strippedFences_noLang_legacy() throws {
        let raw = "```\n{\"name\": \"x\", \"calories_kcal\": 100, \"protein_g\": 5, \"fat_g\": 3, \"carbs_g\": 12, \"confidence\": \"low\", \"note\": \"\"}\n```"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "x")
    }

    func test_parse_surroundingChatter_legacy() throws {
        let raw = "好的，这是估算：{\"name\": \"沙拉\", \"calories_kcal\": 180, \"protein_g\": 8, \"fat_g\": 12, \"carbs_g\": 6, \"confidence\": \"medium\", \"note\": \"\"} 希望有帮助。"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "沙拉")
        XCTAssertEqual(est.items.first?.calories_kcal, 180)
    }

    func test_parse_malformed_throws() {
        XCTAssertThrowsError(try MealNutritionAnalyzer.parse("totally not json"))
    }

    func test_parse_missingOptionalFields_okay_legacy() throws {
        // calories_kcal etc. are optional Doubles
        let raw = "{\"name\": \"未知\"}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "未知")
        XCTAssertNil(est.items.first?.calories_kcal)
    }

    // MARK: - Python-dict tolerance (GLM-4V-Flash regression: model returned a
    // Python dict literal instead of strict JSON, causing parse failures in v5)

    func test_parse_pythonSingleQuotes() throws {
        let raw = "{'name': '豆浆和鸡蛋', 'calories_kcal': 280, 'protein_g': 18, 'fat_g': 12, 'carbs_g': 22, 'confidence': 'medium', 'note': 'OK'}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "豆浆和鸡蛋")
        XCTAssertEqual(est.items.first?.calories_kcal, 280)
        XCTAssertEqual(est.confidence, "medium")
    }

    func test_parse_pythonNoneAndBooleans() throws {
        // Note: confidence is a String, not a Bool — but we exercise the None translation
        // on `note` and trailing-comma robustness here.
        let raw = "{'name': '色拉', 'calories_kcal': 180, 'protein_g': 6, 'fat_g': 10, 'carbs_g': 14, 'confidence': 'low', 'note': None,}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "色拉")
        XCTAssertNil(est.note)
    }

    func test_parse_pythonScriptWrapper() throws {
        // Whole thing wrapped in a "script" — but our extractor still picks the first
        // `{`…last `}`, then relaxes the python-dict syntax.
        let raw = """
        ```python
        result = {
            'name': '番茄炒蛋',
            'calories_kcal': 320,
            'protein_g': 14,
            'fat_g': 22,
            'carbs_g': 10,
            'confidence': 'medium',
            'note': None
        }
        print(result)
        ```
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.first?.name, "番茄炒蛋")
        XCTAssertEqual(est.items.first?.calories_kcal, 320)
        XCTAssertEqual(est.confidence, "medium")
        XCTAssertNil(est.note)
    }

    func test_parse_itemsSchema_pythonSingleQuotes() throws {
        // GLM-4V might also python-ify the new items schema.
        let raw = "{'items': [{'name': '米饭', 'grams': 200, 'calories_kcal': 260, 'protein_g': 5, 'fat_g': 0.6, 'carbs_g': 58}], 'confidence': 'medium', 'note': None}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.items.count, 1)
        XCTAssertEqual(est.items.first?.name, "米饭")
        XCTAssertEqual(est.items.first?.grams, 200)
        XCTAssertNil(est.note)
    }

    func test_relax_doesNotMangleNoodleOrTruffle() {
        // Token-boundary check: "Noodle" / "Truffle" / "Falsehood" should not be touched.
        let out1 = MealNutritionAnalyzer.relaxPythonDict("\"Noodle\"")
        XCTAssertEqual(out1, "\"Noodle\"")
        let out2 = MealNutritionAnalyzer.relaxPythonDict("Truffle")
        XCTAssertEqual(out2, "Truffle")
        let out3 = MealNutritionAnalyzer.relaxPythonDict("Falsehood")
        XCTAssertEqual(out3, "Falsehood")
    }

    func test_relax_preservesChineseInDoubleQuotedStrings() {
        // 'name': '土豆，胡萝卜' contains an ASCII-looking comma inside the value;
        // the relaxer must convert the quotes without splitting on that comma.
        let input = "{'name': '土豆，胡萝卜', 'calories_kcal': 100}"
        let out = MealNutritionAnalyzer.relaxPythonDict(input)
        XCTAssertTrue(out.contains("\"土豆，胡萝卜\""))
    }

    func test_downscale_smallImage_unchanged() {
        let img = makeImage(size: CGSize(width: 100, height: 100))
        let out = LLMClient.downscale(img, maxSide: 768)
        XCTAssertEqual(out.size.width, 100)
        XCTAssertEqual(out.size.height, 100)
    }

    func test_downscale_largeImage_bounded() {
        let img = makeImage(size: CGSize(width: 3000, height: 4000))
        let out = LLMClient.downscale(img, maxSide: 768)
        let longSide = max(out.size.width, out.size.height)
        XCTAssertLessThanOrEqual(longSide, 768 + 0.5, "long side should be ≤ maxSide")
        // aspect preserved
        XCTAssertEqual(out.size.width / out.size.height, 3000.0 / 4000.0, accuracy: 0.001)
    }

    func test_visionRequest_encodes_imageDataURL() throws {
        let req = LLMClient.VisionRequest(model: "glm-4v-flash", messages: [
            LLMClient.VisionMessage(role: "user", content: [
                .text("describe"),
                .imageDataURL("data:image/jpeg;base64,AAAA")
            ])
        ])
        let json = try JSONEncoder().encode(req)
        let str = String(data: json, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"model\":\"glm-4v-flash\""))
        XCTAssertTrue(str.contains("\"type\":\"image_url\""))
        // JSONEncoder escapes forward slashes by default → "data:image\/jpeg;..."
        XCTAssertTrue(str.contains("base64,AAAA"))
        XCTAssertTrue(str.contains("\"role\":\"user\""))

        // Round-trip via JSONSerialization to catch genuinely-broken structure (e.g.
        // missing image_url wrapper) without depending on key/escape formatting.
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let messages = obj?["messages"] as? [[String: Any]]
        let userContent = messages?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(userContent?.count, 2)
        let imagePart = userContent?.last
        XCTAssertEqual(imagePart?["type"] as? String, "image_url")
        let imageURLObj = imagePart?["image_url"] as? [String: Any]
        XCTAssertEqual(imageURLObj?["url"] as? String, "data:image/jpeg;base64,AAAA")
    }

    private func makeImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
