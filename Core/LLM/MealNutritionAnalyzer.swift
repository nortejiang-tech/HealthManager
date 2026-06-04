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
    struct Item: Codable, Equatable, Sendable {
        var name: String
        var grams: Double?
        var calories_kcal: Double?
        var protein_g: Double?
        var fat_g: Double?
        var carbs_g: Double?
    }

    /// Multi-item estimate. The model is asked to break a photo into one item per
    /// dish/food so the user can edit grams per item and re-scale macros locally.
    struct Estimate: Equatable, Sendable {
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

    /// System prompt for the text-only path. Rewritten to give the model concrete portion
    /// references, three few-shot examples covering the typical failure modes (quantity-only
    /// input, brand/dish names, modifiers like "不要酱"), and tight JSON discipline.
    /// The few-shot is intentionally compact — large enough to anchor the output shape
    /// without bloating token cost.
    static let textSystemPrompt: String = """
    你是一名中餐与西餐都熟悉的营养估算助手。用户会用一句话描述这一餐吃了什么；你的任务是把它拆成具体食物，估算份量与三大营养素。

    【方法】
    1. 把描述里的每一种食物 / 菜品识别出来，每种作为 items 数组的一项；连带的酱料、配菜只要影响热量就单列或并入主菜（在 note 里说明你怎么处理的）。
    2. 优先按描述里的**数量词**计算份量（"两碗"、"一份"、"十个"…）；缺数量时用下表里的"典型份量"作为默认。
    3. 做法 / 修饰词必须影响估算：
       - "油炸 / 红烧 / 糖醋"→油糖偏高
       - "清蒸 / 白灼 / 不要酱 / 走油"→脂肪与热量下调
       - "加辣 / 微辣"→对热量影响很小，不必加
       - "套餐 / 全家桶"→默认包含主食、肉、配菜、饮料
    4. 估算保守，宁可偏低；不要把同一种食物拆成多条互相重复。
    5. 在 note 里**简短说明假设**（默认份量、是否包含酱料等），让用户能判断是否合理。

    【典型份量参考】（缺数量时使用）
    - 米饭 1 碗 ≈ 150g（约 200 kcal）
    - 面条 1 碗 ≈ 200g 熟（约 250 kcal）
    - 水饺 / 馄饨 1 只 ≈ 20–25g（10 只约 220g）
    - 包子 1 个 ≈ 80–100g
    - 中式炒菜 1 份 ≈ 200g
    - 汉堡 1 个 ≈ 200–230g（巨无霸约 540 kcal）
    - 鸡蛋 1 个 ≈ 50g（约 70 kcal）
    - 牛奶 / 豆浆 1 杯 ≈ 240ml
    - 苹果 / 香蕉 中等 1 个 ≈ 150 / 120g

    【输出格式】严格 JSON 字面量，从 `{` 开始到 `}` 结束。不要 markdown 围栏、不要任何解释性前缀，不要 Python/JS 代码 / None / True / False / 单引号，布尔小写、空值 null。
    schema：
    {
      "items": [
        {"name": "<中文菜名>", "grams": <份量g 数字>, "calories_kcal": <kcal 数字>, "protein_g": <g>, "fat_g": <g>, "carbs_g": <g>}
      ],
      "confidence": "low" | "medium" | "high",
      "note": "<简短说明你做的假设；无可说则给空串>"
    }
    无法识别为食物时返回 `{"items":[],"confidence":"low","note":"<原因>"}`，仍是合法 JSON。

    【示例 1】（数量明确）
    输入："十个猪肉芹菜水饺，没蘸料"
    输出：{"items":[{"name":"猪肉芹菜水饺","grams":230,"calories_kcal":480,"protein_g":19,"fat_g":17,"carbs_g":62}],"confidence":"medium","note":"10 个约 230g；未蘸酱故脂肪未上调"}

    【示例 2】（连锁餐品 + 修饰）
    输入："麦香鱼汉堡，不要塔塔酱，加杯无糖美式"
    输出：{"items":[{"name":"麦香鱼汉堡（无酱）","grams":135,"calories_kcal":330,"protein_g":15,"fat_g":12,"carbs_g":40},{"name":"无糖美式咖啡（中杯）","grams":350,"calories_kcal":5,"protein_g":0,"fat_g":0,"carbs_g":1}],"confidence":"medium","note":"去塔塔酱按减 80kcal/8g 脂肪；美式无糖按几乎零热量"}

    【示例 3】（缺份量 + 多项）
    输入："午餐套餐：宫保鸡丁加米饭再加一份炒青菜"
    输出：{"items":[{"name":"宫保鸡丁","grams":200,"calories_kcal":380,"protein_g":22,"fat_g":24,"carbs_g":18},{"name":"米饭","grams":150,"calories_kcal":200,"protein_g":4,"fat_g":0.4,"carbs_g":45},{"name":"清炒青菜","grams":200,"calories_kcal":90,"protein_g":3,"fat_g":6,"carbs_g":6}],"confidence":"medium","note":"按典型份量：宫保鸡丁一份 200g、米饭一碗 150g、炒青菜一份 200g"}

    现在请处理用户的下一条输入。仅返回 JSON。
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
                user: "输入：\(trimmed)",
                temperature: 0.1
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
