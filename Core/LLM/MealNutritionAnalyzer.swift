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
    /// 1. Strip reasoning blocks (`<think>…</think>`) emitted by thinking models (qwen3 等)
    /// 2. Strip ```json / ``` fences if present
    /// 3. Trim to the first `{`…last `}` substring
    /// 4. Decode strict, then relaxed (Python-dict→JSON); prefer the first non-empty estimate
    /// 5. If still empty, recover an items array from an alternate / nested key
    /// 6. Otherwise return an explicitly-empty estimate (model said "not food") or throw —
    ///    in both the empty and throw cases the raw reply is logged so failures are diagnosable.
    static func parse(_ raw: String) throws -> Estimate {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Thinking models (qwen3-vl, deepseek-r1, …) wrap reasoning in <think>…</think>.
        // That reasoning routinely contains stray braces, which would corrupt the
        // first-`{`…last-`}` extraction below — strip it before anything else.
        s = stripReasoningBlocks(s)

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

        // Build candidate JSON strings to try, in priority order:
        //  1. first-`{`…last-`}` slice (handles plain surrounding chatter), then
        //  2. each balanced top-level `{…}` block, last one first (handles reasoning that
        //     contains stray braces followed by the real JSON — e.g. unclosed <think>).
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ str: String) {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            candidates.append(t)
        }
        if let openIdx = s.firstIndex(of: "{"),
           let closeIdx = s.lastIndex(of: "}"),
           openIdx <= closeIdx {
            add(String(s[openIdx...closeIdx]))
        }
        for obj in topLevelObjects(s).reversed() { add(obj) }

        let decoder = JSONDecoder()
        // For each candidate try strict then Python-relaxed decode; a non-empty estimate
        // wins immediately, otherwise we keep looking (alternate keys, then explicit-empty).
        var emptyDecoded: Estimate?
        for cand in candidates {
            for variant in [cand, relaxPythonDict(cand)] {
                if let data = variant.data(using: .utf8),
                   let est = try? decoder.decode(Estimate.self, from: data) {
                    if !est.items.isEmpty { return est }
                    emptyDecoded = emptyDecoded ?? est
                }
                // Model may have used a different / nested key (`foods`, `result.items` …).
                if let est = recoverAlternateItems(from: variant) { return est }
            }
        }

        // If the model *explicitly* returned `items: []` / a name-less object (e.g. "不是食物"),
        // honor that empty estimate rather than throwing — but log so it's diagnosable.
        if let est = emptyDecoded, hasExplicitItemsOrName(candidates) {
            AppLogger.shared.error("Nutrition parse: model returned no items. raw=\(raw.prefix(800))")
            return est
        }

        AppLogger.shared.error("Nutrition parse failed (unrecognized shape). raw=\(raw.prefix(800))")
        throw AnalyzeError.parseFailure(rawSnippet: String(raw.prefix(200)))
    }

    /// Remove `<think>…</think>` (and `<thinking>` / `<reasoning>`) reasoning blocks emitted by
    /// thinking models. Closed blocks are removed whole; an unclosed opening tag has just the
    /// tag token removed (its braces-laden body is then filtered out by `topLevelObjects`).
    static func stripReasoningBlocks(_ input: String) -> String {
        var s = input
        let tags = [("<think>", "</think>"), ("<thinking>", "</thinking>"), ("<reasoning>", "</reasoning>")]
        for (open, close) in tags {
            while let openRange = s.range(of: open, options: .caseInsensitive) {
                if let closeRange = s.range(of: close, options: .caseInsensitive,
                                            range: openRange.upperBound..<s.endIndex) {
                    s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // Unclosed: drop only the opening tag; keep the body for brace extraction.
                    s.removeSubrange(openRange)
                    break
                }
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return every balanced top-level `{…}` object substring, in source order. String
    /// contents (with escapes) are skipped so braces inside JSON strings don't miscount.
    static func topLevelObjects(_ s: String) -> [String] {
        var result: [String] = []
        let chars = Array(s)
        var depth = 0
        var start: Int?
        var inString = false
        var prev: Character = " "
        for (i, c) in chars.enumerated() {
            if inString {
                if c == "\"" && prev != "\\" { inString = false }
                prev = c
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let st = start {
                        result.append(String(chars[st...i]))
                        start = nil
                    }
                }
            default: break
            }
            prev = c
        }
        return result
    }

    /// Recover a meal estimate when the food list lives under a non-`items` key or nested
    /// inside another object. Returns nil if no array of name-bearing dicts can be found.
    static func recoverAlternateItems(from jsonString: String) -> Estimate? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let arr = findItemArray(obj) else { return nil }
        let items = arr.compactMap(itemFromDict)
        guard !items.isEmpty else { return nil }
        let top = obj as? [String: Any]
        return Estimate(items: items,
                        confidence: top?["confidence"] as? String,
                        note: top?["note"] as? String)
    }

    /// Recursively locate the first array of dictionaries that looks like a food-items list
    /// (preferred keys first, then any array whose elements carry a `name`).
    private static func findItemArray(_ obj: Any) -> [[String: Any]]? {
        if let dict = obj as? [String: Any] {
            for key in ["items", "foods", "dishes", "meals", "results", "data", "list", "食物", "菜品"] {
                if let arr = dict[key] as? [[String: Any]],
                   arr.contains(where: { $0["name"] != nil }) {
                    return arr
                }
            }
            for value in dict.values {
                if let found = findItemArray(value) { return found }
            }
        }
        if let array = obj as? [Any] {
            let dicts = array.compactMap { $0 as? [String: Any] }
            if !dicts.isEmpty, dicts.count == array.count,
               dicts.contains(where: { $0["name"] != nil }) {
                return dicts
            }
            for value in array {
                if let found = findItemArray(value) { return found }
            }
        }
        return nil
    }

    private static func itemFromDict(_ d: [String: Any]) -> Item? {
        guard let name = (d["name"] as? String), !name.isEmpty else { return nil }
        func dbl(_ k: String) -> Double? {
            switch d[k] {
            case let v as Double: return v
            case let v as Int: return Double(v)
            case let v as NSNumber: return v.doubleValue
            case let v as String: return Double(v)
            default: return nil
            }
        }
        return Item(name: name, grams: dbl("grams"),
                    calories_kcal: dbl("calories_kcal"), protein_g: dbl("protein_g"),
                    fat_g: dbl("fat_g"), carbs_g: dbl("carbs_g"))
    }

    /// True when a candidate's top-level object explicitly carries an `items` array or a
    /// legacy `name` — used to honor a deliberate empty result instead of throwing.
    private static func hasExplicitItemsOrName(_ candidates: [String]) -> Bool {
        for cand in candidates {
            if let data = cand.data(using: .utf8),
               let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               top["items"] != nil || top["name"] != nil {
                return true
            }
        }
        return false
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
