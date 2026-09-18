import Foundation

/// 跨语言检索词（2026-09-18 方案 §3.3）：
/// USDA 资料库没有中文数据——中文查询需转换为官方库支持的英文检索词。
/// 优先本地可追溯词典；词典未覆盖且已配置文本模型时，由模型产出**检索词**
/// （模型输出只用于搜索，绝不产出营养值）；都不可用则回退原词并如实展示。
enum CrossLanguageSearchTermService {

    /// 词典资源（随包、可版本化、可追溯）。
    static let dictionaryResourceName = "food_search_dictionary_v1"

    struct Entry: Codable, Equatable, Sendable {
        let zh: String
        let en: String
    }

    private static var cachedDictionary: [Entry]?

    /// 加载内置词典（zh → en 检索词）。
    static func loadDictionary(bundle: Bundle = .main) -> [Entry] {
        if let cachedDictionary { return cachedDictionary }
        guard let url = bundle.url(forResource: dictionaryResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            cachedDictionary = []
            return []
        }
        cachedDictionary = entries
        return entries
    }

    /// 词典命中：整词相等优先，其次查询包含词条/词条包含查询。
    static func dictionaryTerm(for query: String, dictionary: [Entry]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let exact = dictionary.first(where: { $0.zh.lowercased() == trimmed }) {
            return exact.en
        }
        if let contains = dictionary.first(where: {
            trimmed.contains($0.zh.lowercased()) || $0.zh.lowercased().contains(trimmed)
        }) {
            return contains.en
        }
        return nil
    }

    /// LLM 翻译（仅检索词）。注入 callable 便于测试。
    static func translatedTerm(
        query: String,
        call: @Sendable (_ system: String, _ user: String) async throws -> String
    ) async throws -> String? {
        let system = """
        你是食品检索助手。把用户的中文食物名翻译成 USDA FoodData Central（英文资料库）最合适的英文检索词。
        只输出一个英文检索短语本身，不要解释、不要引号、不要列出多个候选。
        例子：黑巧克力 70-85% → dark chocolate 70-85% cacao；无糖豆浆 → unsweetened soymilk。
        """
        let raw = try await call(system, query)
        let cleaned = LLMClient.stripThinkBlocks(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        // 基本净化：只接受无换行的短短语，防模型长篇输出。
        let single = cleaned.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        guard !single.isEmpty, single.count <= 80,
              single.range(of: "^[A-Za-z0-9 ,%-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return single
    }
}
