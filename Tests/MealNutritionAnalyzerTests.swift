import XCTest
import UIKit
@testable import HealthManager

final class MealNutritionAnalyzerTests: XCTestCase {

    func test_parse_plainJSON() throws {
        let raw = """
        {"name": "番茄炒蛋", "calories_kcal": 320, "protein_g": 14, "fat_g": 22, "carbs_g": 10, "confidence": "medium", "note": "估算保守"}
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.name, "番茄炒蛋")
        XCTAssertEqual(est.calories_kcal, 320)
        XCTAssertEqual(est.protein_g, 14)
        XCTAssertEqual(est.fat_g, 22)
        XCTAssertEqual(est.carbs_g, 10)
        XCTAssertEqual(est.confidence, "medium")
        XCTAssertEqual(est.note, "估算保守")
    }

    func test_parse_strippedFences_json() throws {
        let raw = """
        ```json
        {"name": "拉面", "calories_kcal": 550, "protein_g": 22, "fat_g": 18, "carbs_g": 70, "confidence": "high", "note": null}
        ```
        """
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.name, "拉面")
        XCTAssertEqual(est.confidence, "high")
        XCTAssertNil(est.note)
    }

    func test_parse_strippedFences_noLang() throws {
        let raw = "```\n{\"name\": \"x\", \"calories_kcal\": 100, \"protein_g\": 5, \"fat_g\": 3, \"carbs_g\": 12, \"confidence\": \"low\", \"note\": \"\"}\n```"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.name, "x")
    }

    func test_parse_surroundingChatter() throws {
        let raw = "好的，这是估算：{\"name\": \"沙拉\", \"calories_kcal\": 180, \"protein_g\": 8, \"fat_g\": 12, \"carbs_g\": 6, \"confidence\": \"medium\", \"note\": \"\"} 希望有帮助。"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.name, "沙拉")
        XCTAssertEqual(est.calories_kcal, 180)
    }

    func test_parse_malformed_throws() {
        XCTAssertThrowsError(try MealNutritionAnalyzer.parse("totally not json"))
    }

    func test_parse_missingOptionalFields_okay() throws {
        // calories_kcal etc. are optional Doubles
        let raw = "{\"name\": \"未知\"}"
        let est = try MealNutritionAnalyzer.parse(raw)
        XCTAssertEqual(est.name, "未知")
        XCTAssertNil(est.calories_kcal)
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
