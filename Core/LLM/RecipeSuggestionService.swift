import Foundation

/// 配方推测服务（2026-09-18 方案 §5.2）：
/// 历史/菜名上下文 → 模型建议原料与用量 → 服务端校验 → 可编辑初稿。
///
/// 可信边界：
/// - 模型只能引用**给定候选池**里的官方条目 ID（编造 ID 直接拒绝，R3）；
/// - 数值必须有限且非负；模型建议一律标注「推测」（用量状态 estimated）；
/// - 营养值不由模型输出，只由资料适配器/目录提供，本地计算器计算；
/// - 失败分两类：模型失败（保留手动入口）与资料匹配失败（保留待匹配行）。
struct RecipeSuggestionService {

    enum SuggestionError: Error, Equatable, LocalizedError {
        case notConfigured
        case invalidResponse(String)
        case emptySuggestion

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "未配置文本模型（更多 → 设置 → AI 摘要），或改用手动建立配方。"
            case .invalidResponse(let detail):
                return "推测结果未通过校验：\(detail)"
            case .emptySuggestion:
                return "这次推测没有给出可用原料，可重试或手动建立配方。"
            }
        }
    }

    struct Suggestion: Equatable, Sendable {
        /// 已匹配官方候选的原料（含推测克数/状态/快照）。
        let ingredients: [RecipeIngredient]
        /// 模型提到但候选池中没有官方条目的原料名 → 待匹配行。
        let pendingNames: [String]
        let outputGrams: Double?
        let rationale: String
    }

    /// LLM 调用函数（system, user) -> content；生产用 LLMClient，测试可注入固定样本。
    typealias LLMCallable = @Sendable (_ system: String, _ user: String) async throws -> String

    private let call: LLMCallable

    init(call: @escaping LLMCallable) {
        self.call = call
    }

    /// 生产实例：走既有 LLMConfig 文本模型配置。
    static func makeDefault() -> RecipeSuggestionService? {
        guard let client = LLMClient(fromConfig: true) else { return nil }
        return RecipeSuggestionService { system, user in
            try await client.complete(systemPrompt: system, user: user, temperature: 0.3)
        }
    }

    static let systemPrompt = """
    你是中餐家常菜的配方助手。根据菜名、可选的历史份量线索和给定的官方食材候选，推测一份家常做法配方。
    只输出 JSON，不要输出其他文字，格式：
    {"ingredients":[{"id":"候选ID","grams":数字或null,"status":"estimated|notUsed|unknown"}],
     "pending":["没有候选可用的原料名"],
     "output_grams":数字或null,
     "rationale":"一句话说明推测依据"}
    规则：
    - 只能使用候选列表中的 id，绝不编造 id；
    - grams 为该原料进入成品的克数；不确定用 unknown，明确不用（如没放）用 notUsed；
    - 用油单独作为一个原料，克数是估计进入成品的量，不是锅中总投油量；
    - output_grams 是成品可食总重估计；没有把握就填 null；
    - rationale 只用一句话，例如「按常见家常做法推测，油量和成品重量可调整」。
    """

    /// `historyContext`：只放明确的已记录信息（如“近30天记录 7 餐；常见份量 150g”，
    /// 并注明这些是 AI 估计的历史值而非称重事实）。可为空串。
    func suggest(
        dishName: String,
        candidates: [FoodCatalogEntry],
        historyContext: String
    ) async throws -> Suggestion {
        guard !candidates.isEmpty else {
            throw SuggestionError.emptySuggestion
        }
        let poolLines = candidates.map { entry in
            let kcal = entry.nutrients.kcal.value.map { String(format: "%.0f", $0) } ?? "—"
            return "- \(entry.id) | \(entry.nameZh)（\(entry.nameOriginal)）| 每100g \(kcal) kcal | \(entry.preparationState.displayName)"
        }.joined(separator: "\n")

        var user = "菜名：\(dishName)\n"
        if !historyContext.isEmpty {
            user += "历史线索（记录值，非称重事实）：\(historyContext)\n"
        }
        user += "官方食材候选：\n\(poolLines)\n请输出 JSON。"

        let raw = try await call(Self.systemPrompt, user)
        return try Self.parse(raw: raw, candidates: candidates)
    }

    // MARK: - 解析与校验（R3）

    struct RawSuggestion: Decodable {
        struct RawIngredient: Decodable {
            let id: String?
            let grams: Double?
            let status: String?
        }
        let ingredients: [RawIngredient]?
        let pending: [String]?
        let output_grams: Double?
        let rationale: String?
    }

    static func parse(raw: String, candidates: [FoodCatalogEntry]) throws -> Suggestion {
        let cleaned = LLMClient.stripThinkBlocks(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥掉可能的 ```json 围栏。
        let jsonText = Self.extractJSONObject(from: cleaned)
        guard let data = jsonText.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawSuggestion.self, from: data) else {
            throw SuggestionError.invalidResponse("不是合法的 JSON 建议")
        }

        let poolById = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var ingredients: [RecipeIngredient] = []
        var pendingNames: [String] = []

        for rawIngredient in decoded.ingredients ?? [] {
            // 模型无权宣称「已称量」——推测最多是估计；先于映射检查原始值。
            guard rawIngredient.status != "weighed" else {
                throw SuggestionError.invalidResponse("模型不能给出已称量状态")
            }

            let status: RecipeIngredient.AmountStatus
            switch rawIngredient.status {
            case "notUsed": status = .notUsed
            case "unknown", nil, "": status = .unknown
            case "estimated": status = .estimated
            default:
                // 其他值一律按未知处理（模型自造状态不采信）。
                status = .unknown
            }

            guard let id = rawIngredient.id, !id.isEmpty else {
                throw SuggestionError.invalidResponse("原料缺少 id")
            }
            if let grams = rawIngredient.grams {
                guard grams.isFinite, grams >= 0 else {
                    throw SuggestionError.invalidResponse("原料克数非法：\(grams)")
                }
                if grams == 0, status == .estimated {
                    throw SuggestionError.invalidResponse("估计用量不能为 0；请用 notUsed 或 unknown")
                }
            }

            if let entry = poolById[id] {
                let versionLabel = Self.poolVersionLabel(entry: entry)
                let snapshot = IngredientNutritionSnapshot.capture(
                    from: entry,
                    versionLabel: versionLabel,
                    capturedAt: Int64(Date().timeIntervalSince1970)
                )
                ingredients.append(
                    RecipeIngredient(
                        catalogEntryId: entry.id,
                        catalogVersion: versionLabel,
                        nameZh: entry.nameZh,
                        basis: entry.basis,
                        preparationState: entry.preparationState.mealItemState,
                        grams: rawIngredient.grams,
                        amountStatus: status,
                        nutritionSnapshot: snapshot,
                        pendingName: nil
                    )
                )
            } else {
                // 编造 ID：不静默转待匹配——按合同拒绝（R3）。
                throw SuggestionError.invalidResponse("引用了候选池之外的 id：\(id)")
            }
        }

        for name in decoded.pending ?? [] where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            pendingNames.append(name)
        }
        let output = decoded.output_grams
        if let output, !output.isFinite || output < 0 {
            throw SuggestionError.invalidResponse("成品重量非法：\(output)")
        }

        guard !ingredients.isEmpty || !pendingNames.isEmpty else {
            throw SuggestionError.emptySuggestion
        }

        let rationale = decoded.rationale?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "按常见家常做法推测，油量和成品重量可调整。"
        return Suggestion(
            ingredients: ingredients,
            pendingNames: pendingNames,
            outputGrams: (output != nil && output!.isFinite && output! > 0) ? output : nil,
            rationale: rationale
        )
    }

    static func poolVersionLabel(entry: FoodCatalogEntry) -> String {
        // 候选池来自离线目录或个人库合成条目；note 首段常带来源说明。
        // 目录条目以目录 edition 语义为准；这里用稳定可读的标签。
        if entry.source == "MEXT" { return "MEXT-目录" }
        if entry.source == "USDA" { return entry.note.isEmpty ? "USDA" : String(entry.note.prefix(60)) }
        return entry.note.isEmpty ? entry.source : String(entry.note.prefix(60))
    }

    /// 提取首个平衡的 JSON 对象文本。
    static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var inString = false
        var previous: Character = " "
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if char == "\\", previous != "\\" {
                    // 转义字符，跳过判定
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            previous = char
            index = text.index(after: index)
        }
        return String(text[start...])
    }
}
