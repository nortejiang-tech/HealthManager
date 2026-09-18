import Foundation

/// 添加食材的统一候选：本地结果带完整条目；远端（USDA）只有摘要，
/// 营养必须取详情后才可添加（S3——搜索摘要不能冒充完整营养记录）。
struct FoodSearchCandidate: Identifiable, Equatable {
    enum Origin: Equatable {
        case local
        case remoteUSDA(dataType: String, brandOwner: String?)
    }

    enum MatchTier: Equatable {
        /// 规范化后完全同名。
        case exact
        /// 显示名/别名包含完整查询词。
        case strong
        /// 全部词项命中（词序无关），但整体名不完全匹配。
        case medium
        /// 仅部分命中 / 形态词降级 / 错字近似——标「可能匹配」，由用户选取。
        case possible

        var label: String? {
            switch self {
            case .exact, .strong: return nil
            case .medium: return nil
            case .possible: return "可能匹配"
            }
        }
    }

    let id: String
    let title: String
    /// 区分食品所需的限定词（可可含量、生熟、加糖、品牌等），两行展示。
    let qualifiers: String
    let origin: Origin
    let tier: MatchTier
    /// 本地候选的完整条目；远端候选为 nil（须先取详情）。
    let entry: FoodCatalogEntry?
    let remoteFdcId: Int64?

    var isRemote: Bool {
        if case .remoteUSDA = origin { return true }
        return false
    }
}

/// 本地（离线目录 + 个人资料库）与 USDA 远端检索的统一入口。
/// 排序规则（§3.3）：食品身份与加工状态吻合优先 → 名称相似度；限定词不符降级；
/// 模糊候选标记「可能匹配」，绝不静默替用户选首项。
final class FoodSearchService: @unchecked Sendable {

    private let bundled: FoodCatalogStore
    private let personalCatalog: PersonalCatalogStore

    init(bundled: FoodCatalogStore, personalCatalog: PersonalCatalogStore) {
        self.bundled = bundled
        self.personalCatalog = personalCatalog
    }

    // MARK: - 规范化（§3.3）

    /// 空格/大小写/全半角/常见标点折叠；保留数字、百分号与否定词。
    static func normalized(_ raw: String) -> String {
        let compatibility = raw.precomposedStringWithCompatibilityMapping
        let lowered = compatibility.lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.punctuationCharacters.contains(scalar) { return false }
            if scalar == "·" || scalar == "•" { return false }
            return true
        }
        return String(String.UnicodeScalarView(stripped))
    }

    /// 查询词项：按空白切分；无空格的整串作为一个词项（中文习惯）。
    static func queryTerms(_ raw: String) -> [String] {
        let normalizedQuery = normalized(raw)
        guard !normalizedQuery.isEmpty else { return [] }
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }
        return parts.isEmpty ? [normalizedQuery] : parts
    }

    // MARK: - 本地搜索

    func searchLocal(query: String) async -> [FoodSearchCandidate] {
        let bundledEntries = bundled.search(query: "", category: nil)
        let imported = (try? await personalCatalog.allOfficialFoods()) ?? []
        // 去重：同一身份以个人库（含显示名/别名）优先。
        var byId: [String: FoodCatalogEntry] = [:]
        for entry in bundledEntries { byId[entry.id] = entry }
        for food in imported { byId[food.entry.id] = food.entry }

        let ranked = Self.rank(entries: Array(byId.values), query: query)
        return ranked.map { entry, tier in
            FoodSearchCandidate(
                id: entry.id,
                title: entry.nameZh,
                qualifiers: qualifierText(for: entry),
                origin: .local,
                tier: tier,
                entry: entry,
                remoteFdcId: nil
            )
        }
    }

    private func qualifierText(for entry: FoodCatalogEntry) -> String {
        var parts: [String] = []
        if entry.preparationState != .unknown {
            parts.append(entry.preparationState.displayName)
        }
        parts.append("\(entry.source) · \(entry.basis.displayUnit)")
        return parts.joined(separator: " · ")
    }

    // MARK: - 排序与分级

    /// 形态词：候选名里出现查询之外的这些词，说明是另一形态食品（饼干/饮料等），
    /// 降级为「可能匹配」（S2：黑巧克力 ≠ 黑巧克力饼干）。
    static let formKeywords: [String] = [
        "饼干", "蛋糕", "饮料", "糖", "布丁", "派", "威化", "涂层", "夹心",
        "cookie", "biscuit", "cake", "drink", "pudding", "pie", "wafer", "spread"
    ]

    /// (entry, tier) 排好序的结果。
    static func rank(entries: [FoodCatalogEntry], query: String) -> [(FoodCatalogEntry, FoodSearchCandidate.MatchTier)] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else {
            return entries.map { ($0, FoodSearchCandidate.MatchTier.medium) }
        }
        let terms = queryTerms(query)

        struct Scored {
            let entry: FoodCatalogEntry
            let tier: FoodSearchCandidate.MatchTier
            let rank: Int
        }

        var scored: [Scored] = []
        for entry in entries {
            let name = normalized(entry.nameZh)
            let original = normalized(entry.nameOriginal)
            let aliases = entry.aliases.map { normalized($0) }
            let haystacks = [name, original] + aliases

            func containsAll(_ text: String) -> Bool {
                terms.allSatisfy { text.contains($0) }
            }

            let tier: FoodSearchCandidate.MatchTier
            if name == normalizedQuery || aliases.contains(normalizedQuery) {
                tier = .exact
            } else if name.contains(normalizedQuery) || terms.allSatisfy({ name.contains($0) && name.count <= normalizedQuery.count + 12 }) {
                // 显示名直接包含整词 → 强匹配；形态词在查询之外时降级。
                if Self.hasExtraFormKeyword(name: name, terms: terms) {
                    tier = .possible
                } else {
                    tier = .strong
                }
            } else if haystacks.contains(where: containsAll) {
                tier = .medium
            } else if terms.contains(where: { name.contains($0) || aliases.contains { $0.contains($0) } }) {
                tier = .possible
            } else if Self.fuzzyMatch(query: normalizedQuery, name: name) {
                // 轻量错字近似：只标「可能匹配」，不自动选中。
                tier = .possible
            } else {
                continue
            }
            scored.append(Scored(entry: entry, tier: tier, rank: Self.rankValue(tier)))
        }

        return scored
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.entry.nameZh.count < $1.entry.nameZh.count
            }
            .map { ($0.entry, $0.tier) }
    }

    private static func rankValue(_ tier: FoodSearchCandidate.MatchTier) -> Int {
        switch tier {
        case .exact: return 0
        case .strong: return 1
        case .medium: return 2
        case .possible: return 3
        }
    }

    static func hasExtraFormKeyword(name: String, terms: [String]) -> Bool {
        formKeywords.contains { keyword in
            let normalizedKeyword = normalized(keyword)
            guard name.contains(normalizedKeyword) else { return false }
            return !terms.contains { $0.contains(normalizedKeyword) }
        }
    }

    /// 轻量错字近似：编辑距离 ≤1（纯 ASCII 词项）或共享前缀≥2 且重合率 ≥0.6（中文）。
    /// 只用于把候选标成「可能匹配」，不自动选中。
    static func fuzzyMatch(query: String, name: String) -> Bool {
        guard !query.isEmpty, !name.isEmpty else { return false }
        if query.count >= 3, abs(query.count - name.count) <= 2,
           levenshtein(query, name) <= 1 {
            return true
        }
        let shared = Set(query).intersection(Set(name)).count
        let denominator = max(query.count, 1)
        return Set(query).isSubset(of: Set(name)) && Double(shared) / Double(denominator) >= 0.6
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for i in 1...lhs.count {
            var current = [i]
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    // MARK: - 配方推测候选池

    /// 为菜名构建推测候选池：菜名整体 + 2~4 字滑窗探测（中文名无分格）+ 油/盐/酱油种子。
    /// 只收集 exact/strong/medium 命中；possible 噪声不进池（模型编不进官方 ID 就会转待匹配）。
    func ingredientPool(forDishName dishName: String, limit: Int = 18) async -> [FoodCatalogEntry] {
        let bundledEntries = bundled.search(query: "", category: nil)
        let imported = (try? await personalCatalog.allOfficialFoods()) ?? []
        var byId: [String: FoodCatalogEntry] = [:]
        for entry in bundledEntries { byId[entry.id] = entry }
        for food in imported { byId[food.entry.id] = food.entry }
        let universe = Array(byId.values)

        var probes: [String] = [dishName]
        let characters = Array(dishName)
        var seen: Set<String> = [dishName]
        for length in 2...min(4, max(2, characters.count)) {
            for start in 0...(max(0, characters.count - length)) {
                let window = String(characters[start..<min(start + length, characters.count)])
                if window.count >= 2, seen.insert(window).inserted {
                    probes.append(window)
                }
            }
        }
        probes.append(contentsOf: ["菜籽油", "食盐", "酱油"])

        var pool: [FoodCatalogEntry] = []
        var poolIds: Set<String> = []
        for probe in probes {
            for (entry, tier) in Self.rank(entries: universe, query: probe) {
                if tier == .possible { continue }
                if poolIds.insert(entry.id).inserted {
                    pool.append(entry)
                }
                if pool.count >= limit { return pool }
            }
        }
        return pool
    }

    // MARK: - USDA 远端

    /// 远端候选（摘要）。营养在用户点选后经 `detail` 取回（S3/S5）。
    func searchRemoteUSDA(query: String, client: USDAApiClient) async -> Result<[FoodSearchCandidate], USDAServiceError> {
        do {
            let hits = try await client.search(query: query)
            let candidates = hits.compactMap { hit -> FoodSearchCandidate? in
                // 品牌标签类型不进入首版检索结果（文档 §4.1）。
                guard USDAFoodMapper.supportedDataTypes.contains(hit.dataType) else { return nil }
                let qualifierParts = [hit.dataType, hit.brandOwner].compactMap { $0 }
                return FoodSearchCandidate(
                    id: "usda-\(hit.fdcId)",
                    title: hit.description,
                    qualifiers: qualifierParts.joined(separator: " · "),
                    origin: .remoteUSDA(dataType: hit.dataType, brandOwner: hit.brandOwner),
                    tier: .possible,
                    entry: nil,
                    remoteFdcId: hit.fdcId
                )
            }
            return .success(candidates)
        } catch let error as USDAServiceError {
            return .failure(error)
        } catch {
            return .failure(.badResponse(error.localizedDescription))
        }
    }
}
