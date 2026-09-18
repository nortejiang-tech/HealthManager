import Foundation

/// USDA FoodData Central API Key 存取（Keychain，模式与 LLMConfig 一致）。
/// key 不写入仓库、日志或备份；测试宿主下 Keychain 不可用时回退 UserDefaults（可见日志）。
enum USDAKeyStore {
    static let keychainService = "com.norte.HealthManager.usda"
    static let account = "fdc.apiKey"
    private static let fallbackKey = "usda.kc.fallback.\(account)"

    static var apiKey: String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackKey) ?? ""
    }

    static func setApiKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        guard !trimmed.isEmpty else {
            SecItemDelete(q as CFDictionary)
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return
        }
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.shared.error("USDA keychain write failed (OSStatus=\(status)); fallback to UserDefaults")
            UserDefaults.standard.set(trimmed, forKey: fallbackKey)
        }
    }

    static var isConfigured: Bool { !apiKey.isEmpty }
}

/// USDA FDC 远端数据源错误。区分未配置 / 鉴权 / 限流 / 超时 / 断网 / 响应异常，
/// 不用一条「未找到」掩盖原因（S4）。
enum USDAServiceError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case timeout
    case offline
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 USDA API Key（更多 → 设置 → 食材资料库）"
        case .unauthorized:
            return "USDA 拒绝了 API Key（401），请检查 Key 是否有效"
        case .rateLimited(let seconds):
            return seconds.map { "USDA 限流（429），约 \($0) 秒后可重试" } ?? "USDA 限流（429），请稍后重试"
        case .timeout:
            return "USDA 请求超时，本地搜索仍可用"
        case .offline:
            return "网络不可用；已添加的食材与配方离线可用"
        case .badResponse(let detail):
            return "USDA 响应异常：\(detail)"
        }
    }
}

/// USDA FoodData Central 客户端。`fetcher` 可注入以便测试；生产用 URLSession。
final class USDAApiClient: @unchecked Sendable {

    /// 搜索结果行（摘要，不含营养——营养必须取详情，S3）。
    struct SearchHit: Equatable, Sendable {
        let fdcId: Int64
        let description: String
        let dataType: String
        let brandOwner: String?
    }

    struct FoodDetail: Equatable, Sendable {
        let fdcId: Int64
        let description: String
        let dataType: String
        let publicationDate: String?
        /// 按来源 nutrient ID 映射后的每 100 g 值（含 trace/缺失语义）。
        let mapped: USDAFoodMapper.MappedNutrients
    }

    static let defaultBaseURL = URL(string: "https://api.nal.usda.gov/fdc/v1")!
    /// 首版默认数据类型：分析/汇编类通用食品；品牌标签数据后续扩展。
    static let defaultDataTypes = ["Foundation", "SR Legacy", "FNDDS"]

    private let baseURL: URL
    private let session: URLSession
    private let fetcher: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        baseURL: URL = USDAApiClient.defaultBaseURL,
        fetcher: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) {
        self.baseURL = baseURL
        self.fetcher = fetcher
        self.session = URLSession.shared
    }

    static func defaultFetcher(timeout: TimeInterval = 15) -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: sessionConfig)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw USDAServiceError.badResponse("非 HTTP 响应")
            }
            return (data, http)
        }
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> Data {
        guard USDAKeyStore.isConfigured else { throw USDAServiceError.notConfigured }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        items.append(URLQueryItem(name: "api_key", value: USDAKeyStore.apiKey))
        components.queryItems = items
        let request = URLRequest(url: components.url!)
        do {
            let (data, http) = try await fetcher(request)
            switch http.statusCode {
            case 200:
                return data
            case 401, 403:
                throw USDAServiceError.unauthorized
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Int($0) }
                throw USDAServiceError.rateLimited(retryAfterSeconds: retryAfter)
            default:
                throw USDAServiceError.badResponse("HTTP \(http.statusCode)")
            }
        } catch let error as USDAServiceError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw USDAServiceError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                throw USDAServiceError.offline
            default:
                throw USDAServiceError.badResponse(error.localizedDescription)
            }
        }
    }

    /// 官方资料库检索。只请求默认数据类型（Foundation / SR Legacy / FNDDS）。
    func search(query: String, pageSize: Int = 25) async throws -> [SearchHit] {
        let data = try await request(
            path: "foods/search",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "dataType", value: USDAApiClient.defaultDataTypes.joined(separator: ",")),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
                URLQueryItem(name: "requireAllWords", value: "false")
            ]
        )
        return try Self.parseSearch(data: data)
    }

    /// 完整详情（营养值只在详情层取得；搜索摘要不能冒充完整记录，S3）。
    func detail(fdcId: Int64) async throws -> FoodDetail {
        let data = try await request(path: "food/\(fdcId)", query: [])
        return try Self.parseDetail(data: data)
    }

    // MARK: - 解析（内部可见便于测试）

    struct RawSearchResponse: Decodable {
        struct Food: Decodable {
            let fdcId: Int64
            let description: String
            let dataType: String?
            let brandOwner: String?
        }
        let foods: [Food]?
    }

    static func parseSearch(data: Data) throws -> [SearchHit] {
        do {
            let decoded = try JSONDecoder().decode(RawSearchResponse.self, from: data)
            return (decoded.foods ?? []).compactMap { food in
                guard let dataType = food.dataType else { return nil }
                return SearchHit(
                    fdcId: food.fdcId,
                    description: food.description,
                    dataType: dataType,
                    brandOwner: food.brandOwner
                )
            }
        } catch {
            throw USDAServiceError.badResponse("搜索结果解析失败")
        }
    }

    struct RawDetail: Decodable {
        struct Nutrient: Decodable {
            struct NutrientInfo: Decodable {
                let id: Int64
                let number: String?
                let name: String?
                let unitName: String?
            }
            let nutrient: NutrientInfo?
            let amount: Double?
            let unitName: String?
        }
        let fdcId: Int64
        let description: String
        let dataType: String?
        let publicationDate: String?
        let foodNutrients: [Nutrient]?
    }

    static func parseDetail(data: Data) throws -> FoodDetail {
        do {
            let raw = try JSONDecoder().decode(RawDetail.self, from: data)
            let values = raw.foodNutrients ?? []
            func amount(_ id: Int64) -> FoodCatalogNutrient? {
                guard let entry = values.first(where: { $0.nutrient?.id == id }) else { return nil }
                guard let value = entry.amount else { return FoodCatalogNutrient(value: nil, flag: .unmeasured) }
                return FoodCatalogNutrient(value: value, flag: .measured)
            }
            let kcalDirect = amount(1008)
            let mapped = USDAFoodMapper.MappedNutrients(
                kcal: kcalDirect ?? Self.convertedKcalFromKJ(values),
                proteinG: amount(1003) ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
                fatG: amount(1004) ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
                carbsG: amount(1005) ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
                fiberG: amount(1079) ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
                sodiumMg: amount(1093) ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
                energyRule: kcalDirect != nil
                    ? "energy-1008-kcal"
                    : (Self.hasKJ(values) ? "energy-1062-kj-divided-4.184" : "energy-absent")
            )
            return FoodDetail(
                fdcId: raw.fdcId,
                description: raw.description,
                dataType: raw.dataType ?? "unknown",
                publicationDate: raw.publicationDate,
                mapped: mapped
            )
        } catch let error as USDAServiceError {
            throw error
        } catch {
            throw USDAServiceError.badResponse("详情解析失败")
        }
    }

    private static func hasKJ(_ values: [RawDetail.Nutrient]) -> Bool {
        values.contains { $0.nutrient?.id == 1062 }
    }

    /// 能量口径选择规则（ADR-005）：优先官方 kcal（1008）；仅当其缺失而官方 kJ（1062）
    /// 存在时，做单位换算（÷4.184），flag 标记 estimated 并记录规则——绝不以 4/4/9 重算，
    /// 也不把两种口径相加。
    private static func convertedKcalFromKJ(_ values: [RawDetail.Nutrient]) -> FoodCatalogNutrient? {
        guard let kj = values.first(where: { $0.nutrient?.id == 1062 })?.amount else { return nil }
        return FoodCatalogNutrient(value: kj / 4.184, flag: .estimated)
    }
}

/// USDA 官方值 → App 目录条目映射（§4.3 数据映射硬要求）。
enum USDAFoodMapper {

    struct MappedNutrients: Equatable, Sendable {
        let kcal: FoodCatalogNutrient?
        let proteinG: FoodCatalogNutrient?
        let fatG: FoodCatalogNutrient?
        let carbsG: FoodCatalogNutrient?
        let fiberG: FoodCatalogNutrient?
        let sodiumMg: FoodCatalogNutrient?
        /// 已采用的能量口径规则，随快照留存。
        let energyRule: String
    }

    enum MapError: Error, Equatable, LocalizedError {
        case unsupportedDataType(String)
        case missingNutrients

        var errorDescription: String? {
            switch self {
            case .unsupportedDataType(let type):
                return "暂不支持的数据类型：\(type)（品牌标签类后续扩展）"
            case .missingNutrients:
                return "详情缺少营养值，无法建立每 100 g 基准"
            }
        }
    }

    static let supportedDataTypes: Set<String> = ["Foundation", "SR Legacy", "FNDDS"]

    /// Foundation/SR Legacy/FNDDS 的 foodNutrients 均为每 100 g；
    /// 品牌标签类为每份口径，本轮直接拒绝而不是折算（每份≠每100g）。
    static func entry(from detail: USDAApiClient.FoodDetail) throws -> FoodCatalogEntry {
        guard supportedDataTypes.contains(detail.dataType) else {
            throw MapError.unsupportedDataType(detail.dataType)
        }
        let nutrients = FoodCatalogEntry.Nutrients(
            kcal: detail.mapped.kcal ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
            proteinG: detail.mapped.proteinG ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fatG: detail.mapped.fatG ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
            carbsG: detail.mapped.carbsG ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
            fiberG: detail.mapped.fiberG ?? FoodCatalogNutrient(value: nil, flag: .unmeasured),
            sodiumMg: detail.mapped.sodiumMg ?? FoodCatalogNutrient(value: nil, flag: .unmeasured)
        )
        let edition = detail.publicationDate.map { "FDC-published-\($0)" } ?? "FDC-fetched-\(Self.todayStamp())"
        return FoodCatalogEntry(
            id: "usda-\(detail.fdcId)",
            source: "USDA",
            foodNo: String(detail.fdcId),
            foodGroup: "fdc",
            nameZh: detail.description,
            nameOriginal: detail.description,
            aliases: [],
            category: classify(description: detail.description),
            preparationState: .unknown,
            basis: .per100g,
            refusePercent: nil,
            nutrients: nutrients,
            sourceUrl: "https://fdc.nal.usda.gov/food-details/\(detail.fdcId)/nutrients",
            note: "USDA FoodData Central · \(detail.dataType) · 能量口径 \(detail.mapped.energyRule)"
        )
    }

    /// 版本标签：有官方发布日期用发布日期；否则抓取日期（内容摘要由身份+日期承载）。
    static func versionLabel(for detail: USDAApiClient.FoodDetail, fetchedAt: Date = Date()) -> String {
        if let publicationDate = detail.publicationDate, !publicationDate.isEmpty {
            return "FDC-\(detail.dataType)-published-\(publicationDate)"
        }
        return "FDC-\(detail.dataType)-fetched-\(Self.todayStamp(fetchedAt))"
    }

    /// 粗分类：甜食/零食关键词 → sweetsSnacks；其余 → 其他（不猜具体类目）。
    static func classify(description: String) -> FoodCatalogCategory {
        let lowered = description.lowercased()
        let snackKeywords = ["chocolate", "candy", "cookie", "biscuit", "snack", "pastry", "cake", "dessert"]
        if snackKeywords.contains(where: { lowered.contains($0) }) {
            return .sweetsSnacks
        }
        return .other
    }

    private static func todayStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
