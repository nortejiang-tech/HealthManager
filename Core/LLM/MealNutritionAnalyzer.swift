import Foundation
import UIKit

/// Sends a meal photo to the configured vision LLM and parses back a strict-shape
/// nutrition estimate that can prefill MealEditView's fields directly.
///
/// Output schema (single meal, post-cooking estimate):
/// ```json
/// {"name": "番茄炒蛋", "calories_kcal": 320, "protein_g": 14, "fat_g": 22, "carbs_g": 10, "confidence": "medium"}
/// ```
///
/// We tell the model to **only output JSON** — many models wrap it in ```json fences.
/// The parser is permissive: strip fences, find the first `{`...`}` block, then decode.
enum MealNutritionAnalyzer {

    struct Estimate: Codable, Equatable {
        let name: String
        let calories_kcal: Double?
        let protein_g: Double?
        let fat_g: Double?
        let carbs_g: Double?
        let confidence: String?
        /// Free-form note from the model (e.g. "图片模糊，估算偏保守"). Optional.
        let note: String?
    }

    enum AnalyzeError: LocalizedError {
        case notConfigured
        case llm(Error)
        case parseFailure(rawSnippet: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "尚未配置视觉模型。请到「设置 → AI 摘要」填入 Vision Model 字段。"
            case .llm(let e):
                return "视觉模型调用失败：\(e.localizedDescription)"
            case .parseFailure(let s):
                return "模型返回不是 JSON：\(s)"
            }
        }
    }

    static let systemPrompt: String = """
    你是营养估算助手。用户会提供一张餐食照片。请：
    1. 识别主要食物
    2. 估算整餐的总热量（kcal）、蛋白质（g）、脂肪（g）、碳水（g）
    3. 输出严格的 JSON，不要包裹在 markdown code block 里，也不要任何额外文字
    4. JSON schema：{"name": "中文菜名", "calories_kcal": 数字, "protein_g": 数字, "fat_g": 数字, "carbs_g": 数字, "confidence": "low/medium/high", "note": "可选备注"}
    5. 如果图片不像食物，name 写「无法识别」、所有数字置 0、confidence 写 "low"、note 写明原因
    6. 估算保守一些，宁可偏低不要夸大
    """

    /// Analyze a meal image and return a structured estimate.
    /// `LLMConfig.isVisionConfigured` must be true.
    static func analyze(image: UIImage) async throws -> Estimate {
        guard let client = LLMClient.visionClient() else {
            throw AnalyzeError.notConfigured
        }
        let raw: String
        do {
            raw = try await client.analyzeImage(
                image,
                prompt: "请估算这餐的营养。仅返回 JSON。",
                systemPrompt: systemPrompt,
                temperature: 0.1
            )
        } catch {
            throw AnalyzeError.llm(error)
        }
        return try parse(raw)
    }

    /// Best-effort JSON extractor:
    /// 1. Strip ```json / ``` fences if present
    /// 2. Trim to the first `{`…last `}` substring
    /// 3. Decode
    static func parse(_ raw: String) throws -> Estimate {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip ``` fences (with or without "json" lang tag).
        if s.hasPrefix("```") {
            // remove opening fence line
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
            if let range = s.range(of: "```", options: .backwards) {
                s = String(s[..<range.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fall back to first-`{`…last-`}` if there's surrounding chatter.
        if let openIdx = s.firstIndex(of: "{"),
           let closeIdx = s.lastIndex(of: "}"),
           openIdx <= closeIdx {
            s = String(s[openIdx...closeIdx])
        }

        guard let data = s.data(using: .utf8) else {
            throw AnalyzeError.parseFailure(rawSnippet: String(raw.prefix(200)))
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Estimate.self, from: data)
        } catch {
            throw AnalyzeError.parseFailure(rawSnippet: String(raw.prefix(200)))
        }
    }
}
