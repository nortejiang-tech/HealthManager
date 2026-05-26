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

    /// A single identified food item in a meal photo.
    struct Item: Codable, Equatable {
        var name: String
        var grams: Double?
        var calories_kcal: Double?
        var protein_g: Double?
        var fat_g: Double?
        var carbs_g: Double?
    }

    /// Multi-item estimate. The model is asked to break a photo into one item per
    /// dish/food so the user can edit grams per item and re-scale macros locally.
    struct Estimate: Equatable {
        var items: [Item]
        var confidence: String?
        /// Free-form note from the model (e.g. "图片模糊，估算偏保守"). Optional.
        var note: String?

        var totalCalories: Double { items.compactMap(\.calories_kcal).reduce(0, +) }
        var totalProtein: Double { items.compactMap(\.protein_g).reduce(0, +) }
        var totalFat: Double { items.compactMap(\.fat_g).reduce(0, +) }
        var totalCarbs: Double { items.compactMap(\.carbs_g).reduce(0, +) }
    }

    enum AnalyzeError: LocalizedError {
        case notConfigured
        case notConfiguredText
        case llm(Error)
        case parseFailure(rawSnippet: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "尚未配置视觉模型。请到「设置 → AI 摘要」填入 Vision Model 字段。"
            case .notConfiguredText:
                return "尚未配置文本模型。请到「设置 → AI 摘要」填入 Base URL 与 Text Model。"
            case .llm(let e):
                return "模型调用失败：\(e.localizedDescription)"
            case .parseFailure(let s):
                return "模型返回不是 JSON：\(s)"
            }
        }
    }

    static let systemPrompt: String = """
    你是营养估算助手。用户会提供一张餐食照片。请：
    1. 把图片中的每一种食物或菜品识别出来，每种作为 items 数组的一项
    2. 对每一项估算：name（中文菜名）、grams（份量，克）、calories_kcal、protein_g、fat_g、carbs_g
    3. 输出严格的 JSON，不要包裹在 markdown code block 里，也不要任何额外文字
    4. JSON schema：
       {
         "items": [
           {"name": "米饭", "grams": 200, "calories_kcal": 260, "protein_g": 5, "fat_g": 0.6, "carbs_g": 58},
           {"name": "炒青菜", "grams": 150, "calories_kcal": 60, "protein_g": 3, "fat_g": 4, "carbs_g": 4}
         ],
         "confidence": "low/medium/high",
         "note": "可选备注"
       }
    5. 每个 item 都必须给出 name 和 grams；macros 也尽量给出
    6. 如果图片不像食物，items 写空数组 []、confidence 写 "low"、note 写明原因
    7. 估算保守一些，宁可偏低不要夸大
    8. 严格要求：禁止输出 Python / JavaScript 代码、函数定义、print 语句、注释或 import；禁止使用单引号 / None / True / False。字符串必须双引号，布尔小写 true/false，空值写 null。只输出一个 JSON 对象字面量，从 { 开始到 } 结束。
    """

    /// System prompt for the text-only path: the user types a free-form description
    /// (e.g. "十个芹菜猪肉水饺", "麦香鱼汉堡不要酱") and we estimate macros from it.
    static let textSystemPrompt: String = """
    你是营养估算助手。用户会用一句话描述这一餐吃了什么（可能含数量、份量、做法、是否加酱料等）。请：
    1. 把描述中的每一种食物 / 菜品识别出来，每种作为 items 数组的一项；
    2. 对每一项估算：name（中文菜名）、grams（份量，克；依据描述里的数量/常识推断，如「十个水饺」约 250g）、calories_kcal、protein_g、fat_g、carbs_g；
    3. 认真考虑描述里的数量与做法对份量/热量的影响（如「不要酱」要减少脂肪与热量，「油炸」要增加）；
    4. 输出严格 JSON，不要包裹在 markdown 里，也不要任何额外文字；schema：
       {
         "items": [
           {"name": "猪肉芹菜水饺", "grams": 250, "calories_kcal": 520, "protein_g": 20, "fat_g": 18, "carbs_g": 68}
         ],
         "confidence": "low/medium/high",
         "note": "可选备注"
       }
    5. 每个 item 必须给出 name 和 grams；macros 尽量给出；估算保守一些，宁可偏低；
    6. 如果描述无法识别为食物，items 写空数组 []、confidence 写 "low"、note 写明原因；
    7. 严格要求：禁止输出 Python / JavaScript 代码、函数定义、注释或 import；禁止单引号 / None / True / False。字符串必须双引号，布尔小写 true/false，空值 null。只输出一个 JSON 对象字面量，从 { 开始到 } 结束。
    """

    /// Estimate nutrition from a free-form text description using the configured **text**
    /// model (not vision). Mirrors `analyze(image:)`'s output shape so the UI can reuse the
    /// same item-editing flow.
    static func analyze(text: String) async throws -> Estimate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Estimate(items: [], confidence: "low", note: "描述为空")
        }
        guard let client = LLMClient(fromConfig: true) else {
            throw AnalyzeError.notConfiguredText
        }
        let raw: String
        do {
            raw = try await client.complete(
                systemPrompt: textSystemPrompt,
                user: "用户描述：\(trimmed)\n请按 items 数组估算这一餐的营养，仅返回 JSON。",
                temperature: 0.2
            )
        } catch {
            throw AnalyzeError.llm(error)
        }
        return try parse(raw)
    }

    /// Analyze a meal image and return a structured estimate.
    /// `LLMConfig.isVisionConfigured` must be true.
    ///
    /// - Parameter userHint: Optional correction from the user (e.g. "其实是豆浆和鸡蛋").
    ///   When present, this is fed back to the model so it can recompute macros that
    ///   match what the user said the food actually is, not what it visually guessed.
    static func analyze(image: UIImage, userHint: String? = nil) async throws -> Estimate {
        guard let client = LLMClient.visionClient() else {
            throw AnalyzeError.notConfigured
        }
        let prompt: String = {
            let hint = userHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if hint.isEmpty {
                return "请估算这餐的营养，按 items 数组列出每种食物。仅返回 JSON。"
            }
            return """
            用户已经修正了识别结果：图片中实际上是「\(hint)」。
            请以用户的描述为准（你之前的视觉识别可能有误），把这些食物分别作为 items 数组的项目，
            按用户给出的份量（如有）估算每一项的 grams 和 macros。仅返回 JSON。
            """
        }()
        let raw: String
        do {
            raw = try await client.analyzeImage(
                image,
                prompt: prompt,
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
    /// 3. Try strict JSON; on failure, retry after a Python-dict→JSON relaxation pass.
    static func parse(_ raw: String) throws -> Estimate {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip ``` fences (with or without "json" / "python" / etc. lang tag).
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

        // Fall back to first-`{`…last-`}` if there's surrounding chatter or code.
        if let openIdx = s.firstIndex(of: "{"),
           let closeIdx = s.lastIndex(of: "}"),
           openIdx <= closeIdx {
            s = String(s[openIdx...closeIdx])
        }

        let decoder = JSONDecoder()

        // 1. Strict pass.
        if let data = s.data(using: .utf8),
           let est = try? decoder.decode(Estimate.self, from: data) {
            return est
        }

        // 2. Relaxed pass — accommodate GLM-4V-Flash returning Python dict literals:
        //    single quotes, None/True/False, trailing commas, leading `result = ` etc.
        let relaxed = relaxPythonDict(s)
        if let data = relaxed.data(using: .utf8),
           let est = try? decoder.decode(Estimate.self, from: data) {
            return est
        }

        throw AnalyzeError.parseFailure(rawSnippet: String(raw.prefix(200)))
    }

    /// Convert a Python-flavored dict literal into something JSONDecoder accepts.
    /// Best-effort only — used as a fallback when the strict parser fails. We deliberately
    /// keep this conservative: only transform tokens *outside* of double-quoted strings,
    /// so we don't mangle Chinese characters that contain ASCII punctuation in them.
    static func relaxPythonDict(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)

        var inDoubleQuote = false
        var inSingleQuote = false
        var prev: Character = " "

        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]

            if inDoubleQuote {
                out.append(c)
                if c == "\"" && prev != "\\" { inDoubleQuote = false }
                prev = c
                i = input.index(after: i)
                continue
            }

            if inSingleQuote {
                // Translate inside-single-quote contents into a double-quoted string.
                if c == "'" && prev != "\\" {
                    out.append("\"")
                    inSingleQuote = false
                } else if c == "\"" {
                    // Escape any embedded literal double quotes.
                    out.append("\\\"")
                } else {
                    out.append(c)
                }
                prev = c
                i = input.index(after: i)
                continue
            }

            // Not in any string. Look for opening single quote → convert to double quote.
            if c == "'" {
                out.append("\"")
                inSingleQuote = true
                prev = c
                i = input.index(after: i)
                continue
            }

            // Translate Python None / True / False as standalone tokens (basic word boundary).
            if c == "N" || c == "T" || c == "F" {
                let tail = input[i...]
                if let replaced = matchPythonLiteral(tail) {
                    out.append(replaced.replacement)
                    i = input.index(i, offsetBy: replaced.length)
                    prev = " "
                    continue
                }
            }

            // Drop trailing commas before } or ] which strict JSON forbids.
            if c == "," {
                var j = input.index(after: i)
                while j < input.endIndex, input[j].isWhitespace { j = input.index(after: j) }
                if j < input.endIndex, input[j] == "}" || input[j] == "]" {
                    // Skip this comma.
                    prev = c
                    i = input.index(after: i)
                    continue
                }
            }

            out.append(c)
            if c == "\"" { inDoubleQuote = true }
            prev = c
            i = input.index(after: i)
        }
        return out
    }

    /// Detect `None`, `True`, or `False` at the start of `slice` followed by a
    /// non-identifier character (so we don't mangle `Noodle` or `Truffle`).
    private static func matchPythonLiteral(_ slice: Substring) -> (replacement: String, length: Int)? {
        let candidates: [(String, String)] = [
            ("None", "null"),
            ("True", "true"),
            ("False", "false")
        ]
        for (token, replacement) in candidates {
            if slice.hasPrefix(token) {
                let afterIdx = slice.index(slice.startIndex, offsetBy: token.count)
                let nextIsBoundary: Bool
                if afterIdx >= slice.endIndex {
                    nextIsBoundary = true
                } else {
                    let next = slice[afterIdx]
                    nextIsBoundary = !(next.isLetter || next.isNumber || next == "_")
                }
                if nextIsBoundary {
                    return (replacement, token.count)
                }
            }
        }
        return nil
    }
}

// MARK: - Estimate Codable (with v5 single-dish backward compatibility)
//
// The v6 schema is `{"items": [...], "confidence": ..., "note": ...}` but v5 returned
// `{"name": ..., "calories_kcal": ..., ...}` (a single aggregate object). Tests and any
// older cached responses still produce the v5 shape, so we accept both: if `items` is
// missing we wrap the top-level fields as a single Item.

extension MealNutritionAnalyzer.Estimate: Codable {
    enum CodingKeys: String, CodingKey {
        case items, confidence, note
        // Legacy v5 keys at top level
        case name, grams, calories_kcal, protein_g, fat_g, carbs_g
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)

        if let arr = try c.decodeIfPresent([MealNutritionAnalyzer.Item].self, forKey: .items) {
            self.items = arr
        } else if let legacyName = try c.decodeIfPresent(String.self, forKey: .name) {
            // Wrap v5 single-dish payload as a one-item array.
            self.items = [MealNutritionAnalyzer.Item(
                name: legacyName,
                grams: try c.decodeIfPresent(Double.self, forKey: .grams),
                calories_kcal: try c.decodeIfPresent(Double.self, forKey: .calories_kcal),
                protein_g: try c.decodeIfPresent(Double.self, forKey: .protein_g),
                fat_g: try c.decodeIfPresent(Double.self, forKey: .fat_g),
                carbs_g: try c.decodeIfPresent(Double.self, forKey: .carbs_g)
            )]
        } else {
            self.items = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(note, forKey: .note)
    }
}
