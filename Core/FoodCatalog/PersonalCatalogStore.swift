import Foundation
import GRDB

/// 「我的参考表」与导入官方资料的个人存储（ADR-005）。
///
/// - 首版离线目录 41 条在首次启动时**一次性**初始化为 active 成员；
///   之后启动不再重复初始化——用户移除全部默认条目后不会自动复活（D3）。
///   种子标记随备份 settings 持久化：恢复旧格式备份到新装不重播，恢复 v3 备份后
///   以备份中的成员与移除状态为准。
/// - 移除是 `is_removed` 状态变化：可逆、持久、不产生副本；旧配方引用不受影响。
/// - 添加（本地或 USDA）写入 official_foods + official_food_versions + 成员后再返回，
///   以身份 (provider, providerFoodId) 幂等去重，不按中文名去重。
final class PersonalCatalogStore: @unchecked Sendable {

    enum StoreError: Error, Equatable, LocalizedError {
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let detail):
                return "参考食材操作无效：\(detail)"
            }
        }
    }

    /// 列表/详情共用的行模型：合成目录条目 + 成员状态 + 版本信息。
    struct ReferenceFood: Equatable, Sendable {
        let member: PersonalReferenceEntryRecord
        let version: OfficialFoodVersionRecord
        let food: OfficialFoodRecord
        /// 由版本快照合成的目录条目形态（详情页、加入饮食草稿共用）。
        let entry: FoodCatalogEntry
        /// 成员自定义别名（搜索用；显示名之外的叫法）。
        var aliases: [String] { member.customAliases }
    }

    static let seedFlagKey = "personalCatalog.seeded.v10"

    private let databaseManager: DatabaseManager
    private let now: @Sendable () -> Int64

    init(
        databaseManager: DatabaseManager,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.databaseManager = databaseManager
        self.now = now
    }

    // MARK: - 一次性种子

    /// 首次启动：把随包离线目录初始化为个人参考表 active 成员。
    /// 幂等：以 UserDefaults 标记为准；用户移除后即使表空也不重播。
    func seedIfNeeded(
        bundled: FoodCatalogStore,
        seedFlagReader: @escaping @Sendable (String) -> Bool? = { UserDefaults.standard.object(forKey: $0) as? Bool },
        seedFlagWriter: @escaping @Sendable (String, Bool) -> Void = { UserDefaults.standard.set($1, forKey: $0) }
    ) async throws {
        if seedFlagReader(Self.seedFlagKey) == true { return }
        _ = try await importEntries(
            bundled.catalog.entries.map { entry in
                ImportRequest(
                    entry: entry,
                    displayName: entry.nameZh,
                    versionLabel: bundled.catalog.source.edition,
                    aliases: entry.aliases,
                    activate: true
                )
            }
        )
        seedFlagWriter(Self.seedFlagKey, true)
    }

    /// 导入请求：条目 + 显示名 + 版本标签（+ 可选别名/激活意图）。
    struct ImportRequest {
        let entry: FoodCatalogEntry
        let displayName: String
        let versionLabel: String
        var aliases: [String] = []
        /// false = 仅入库身份与版本，不改成员状态（用于「配方选择器用到但暂不进表」的路径）。
        var activate: Bool = true
    }

    // MARK: - 查询

    /// 当前参考表（active 成员，按加入先后稳定排序；新条目在末尾，便于添加后定位）。
    func activeMembers() async throws -> [ReferenceFood] {
        try await members(removedOnly: false)
    }

    func removedMembers() async throws -> [ReferenceFood] {
        try await members(removedOnly: true)
    }

    /// 在参考表范围内搜索（显示名、自定义别名、原文名；大小写不敏感）。
    func searchMembers(query: String, includeRemoved: Bool = false) async throws -> [ReferenceFood] {
        let all = try await members(removedOnly: includeRemoved ? nil : false)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter { food in
            if food.entry.nameZh.lowercased().contains(trimmed) { return true }
            if food.entry.nameOriginal.lowercased().contains(trimmed) { return true }
            if food.member.displayName.lowercased().contains(trimmed) { return true }
            return food.aliases.contains { $0.lowercased().contains(trimmed) }
        }
    }

    private func members(removedOnly: Bool?) async throws -> [ReferenceFood] {
        try await databaseManager.asyncRead { db in
            var request = PersonalReferenceEntryRecord
                .order(Column("added_at").asc, Column("id").asc)
            if let removedOnly {
                request = request.filter(Column("is_removed") == (removedOnly ? 1 : 0))
            }
            let entries = try request.fetchAll(db)
            let foods = try OfficialFoodRecord.fetchAll(db)
            let versions = try OfficialFoodVersionRecord.fetchAll(db)
            let foodById = Dictionary(uniqueKeysWithValues: foods.compactMap { food in food.id.map { ($0, food) } })
            let versionById = Dictionary(uniqueKeysWithValues: versions.compactMap { version in version.id.map { ($0, version) } })

            return entries.compactMap { entry in
                guard let food = foodById[entry.officialFoodId],
                      let version = versionById[entry.versionId],
                      let catalogEntry = version.catalogEntry(food: food, displayName: entry.displayName) else {
                    return nil
                }
                return ReferenceFood(member: entry, version: version, food: food, entry: catalogEntry)
            }
        }
    }

    // MARK: - 添加 / 移除 / 恢复

    /// 批量导入。以身份与版本去重，幂等：
    /// - 身份不存在 → 建身份 + 版本 + active 成员（activate 时）；
    /// - 身份存在且同版本 → 仅确保成员状态（更新显示名/别名仅当调用方提供）；
    /// - 身份存在但版本更新 → 追加新版本行（旧行不改写），成员版本指针不变。
    /// 返回涉及的成员 id（未激活的导入不建成员，返回空）。
    @discardableResult
    func importEntries(_ requests: [ImportRequest]) async throws -> [Int64] {
        try await databaseManager.asyncWrite { [now = self.now] db in
            var memberIds: [Int64] = []
            for request in requests {
                let entry = request.entry
                let timestamp = now()

                var food = try OfficialFoodRecord
                    .filter(Column("provider") == entry.source)
                    .filter(Column("provider_food_id") == entry.foodNo)
                    .fetchOne(db)
                if food == nil {
                    var newFood = OfficialFoodRecord(
                        id: nil,
                        provider: entry.source,
                        providerFoodId: entry.foodNo,
                        nameOriginal: entry.nameOriginal,
                        createdAt: timestamp
                    )
                    try newFood.insert(db)
                    food = newFood
                }
                guard let foodId = food?.id else {
                    throw StoreError.invalidInput("官方身份未获得 ID")
                }

                var versionId: Int64?
                if let existing = try OfficialFoodVersionRecord
                    .filter(Column("official_food_id") == foodId)
                    .filter(Column("version_label") == request.versionLabel)
                    .fetchOne(db) {
                    versionId = existing.id
                } else {
                    var version = OfficialFoodVersionRecord(
                        id: nil,
                        officialFoodId: foodId,
                        versionLabel: request.versionLabel,
                        basis: entry.basis.rawValue,
                        nutrientsJSON: OfficialFoodVersionRecord.encodeNutrients(entry.nutrients),
                        displayNameZh: entry.nameZh,
                        category: entry.category.rawValue,
                        preparationState: entry.preparationState.rawValue,
                        refusePercent: entry.refusePercent,
                        sourceUrl: entry.sourceUrl,
                        sourceEdition: request.versionLabel,
                        note: entry.note.isEmpty ? nil : entry.note,
                        portionsJSON: OfficialFoodVersionRecord.encodePortions(entry.portions),
                        createdAt: timestamp
                    )
                    try version.insert(db)
                    versionId = version.id
                }
                guard let resolvedVersionId = versionId else {
                    throw StoreError.invalidInput("资料版本未获得 ID")
                }

                let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty else {
                    throw StoreError.invalidInput("显示名为空")
                }

                if var member = try PersonalReferenceEntryRecord
                    .filter(Column("official_food_id") == foodId)
                    .fetchOne(db) {
                    if request.activate {
                        member.isRemoved = false
                        member.displayName = displayName
                        // 版本指针不随导入自动升级（ADR-005 §1.1）：成员继续指向
                        // 自己选用的版本；新版本仅追加行，供「显式采用」流程使用。
                        if !request.aliases.isEmpty {
                            member.customAliasesJSON = PersonalReferenceEntryRecord.encodeAliases(request.aliases)
                        }
                        member.updatedAt = timestamp
                        try member.update(db)
                    }
                    if request.activate { memberIds.append(member.id ?? -1) }
                } else if request.activate {
                    var member = PersonalReferenceEntryRecord(
                        id: nil,
                        officialFoodId: foodId,
                        versionId: resolvedVersionId,
                        displayName: displayName,
                        customAliasesJSON: PersonalReferenceEntryRecord.encodeAliases(request.aliases),
                        isRemoved: false,
                        addedAt: timestamp,
                        updatedAt: timestamp
                    )
                    try member.insert(db)
                    memberIds.append(member.id ?? -1)
                }
            }
            return memberIds
        }
    }

    /// 移除：仅状态变化；重复移除幂等。
    func removeMember(id: Int64) async throws {
        try await setRemoved(id: id, removed: true)
    }

    /// 恢复（重新添加）：恢复成员、不产生副本。
    func restoreMember(id: Int64) async throws {
        try await setRemoved(id: id, removed: false)
    }

    private func setRemoved(id: Int64, removed: Bool) async throws {
        try await databaseManager.asyncWrite { [now = self.now] db in
            guard var member = try PersonalReferenceEntryRecord.fetchOne(db, key: id) else {
                throw StoreError.invalidInput("参考条目不存在（\(id)）")
            }
            member.isRemoved = removed
            member.updatedAt = now()
            try member.update(db)
        }
    }

    /// 可编辑个人显示名；原始名称、来源与营养值不因此改变。
    func setDisplayName(memberId: Int64, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidInput("显示名为空")
        }
        try await databaseManager.asyncWrite { [now = self.now] db in
            guard var member = try PersonalReferenceEntryRecord.fetchOne(db, key: memberId) else {
                throw StoreError.invalidInput("参考条目不存在（\(memberId)）")
            }
            member.displayName = trimmed
            member.updatedAt = now()
            try member.update(db)
        }
    }

    func setCustomAliases(memberId: Int64, aliases: [String]) async throws {
        let cleaned = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        try await databaseManager.asyncWrite { [now = self.now] db in
            guard var member = try PersonalReferenceEntryRecord.fetchOne(db, key: memberId) else {
                throw StoreError.invalidInput("参考条目不存在（\(memberId)）")
            }
            member.customAliasesJSON = PersonalReferenceEntryRecord.encodeAliases(cleaned)
            member.updatedAt = now()
            try member.update(db)
        }
    }

    // MARK: - 成员状态查询（添加页去重：已添加 / 重新添加 / 从未添加）

    func membershipState(provider: String, providerFoodId: String) async throws -> Bool? {
        try await databaseManager.asyncRead { db in
            guard let food = try OfficialFoodRecord
                .filter(Column("provider") == provider)
                .filter(Column("provider_food_id") == providerFoodId)
                .fetchOne(db),
                let foodId = food.id else {
                return nil
            }
            guard let member = try PersonalReferenceEntryRecord
                .filter(Column("official_food_id") == foodId)
                .fetchOne(db) else {
                return nil
            }
            return !member.isRemoved
        }
    }

    // MARK: - 资料版本检索（配方选择器等：含已移除成员，不恢复成员状态）

    /// 全部已导入官方条目（含已移除成员的），供配方选择器等“完整资料范围”使用。
    func allOfficialFoods() async throws -> [ReferenceFood] {
        try await databaseManager.asyncRead { db in
            let foods = try OfficialFoodRecord.fetchAll(db)
            let versions = try OfficialFoodVersionRecord.fetchAll(db)
            let members = try PersonalReferenceEntryRecord.fetchAll(db)
            let foodById = Dictionary(uniqueKeysWithValues: foods.compactMap { food in food.id.map { ($0, food) } })
            let memberByFoodId = Dictionary(members.map { ($0.officialFoodId, $0) }, uniquingKeysWith: { first, _ in first })

            var result: [ReferenceFood] = []
            // 每个身份取最新版本行。
            let latestVersions = Dictionary(grouping: versions, by: \.officialFoodId)
                .compactMapValues { $0.max { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id ?? 0 < $1.id ?? 0 } }
            for (foodId, version) in latestVersions {
                guard let food = foodById[foodId],
                      let catalogEntry = version.catalogEntry(
                        food: food,
                        displayName: memberByFoodId[foodId]?.displayName ?? version.displayNameZh
                      ) else {
                    continue
                }
                guard let member = memberByFoodId[foodId] else {
                    // 仅入库未进表（activate=false 路径）：以空成员形态暴露给选择器。
                    let placeholder = PersonalReferenceEntryRecord(
                        id: nil,
                        officialFoodId: foodId,
                        versionId: version.id ?? 0,
                        displayName: version.displayNameZh,
                        customAliasesJSON: "[]",
                        isRemoved: true,
                        addedAt: version.createdAt,
                        updatedAt: version.createdAt
                    )
                    result.append(ReferenceFood(member: placeholder, version: version, food: food, entry: catalogEntry))
                    continue
                }
                result.append(ReferenceFood(member: member, version: version, food: food, entry: catalogEntry))
            }
            return result.sorted { $0.entry.nameZh < $1.entry.nameZh }
        }
    }

    // MARK: - 配方原料快照

    /// 用可确认的资料版本生成原料快照。身份/版本查不到时返回 nil（待修复，不冒充）。
    func captureSnapshot(entryId: String, capturedAt: Int64) async throws -> IngredientNutritionSnapshot? {
        guard let (provider, providerFoodId) = Self.parseIdentity(entryId) else { return nil }
        return try await databaseManager.asyncRead { db in
            guard let food = try OfficialFoodRecord
                .filter(Column("provider") == provider)
                .filter(Column("provider_food_id") == providerFoodId)
                .fetchOne(db),
                let foodId = food.id,
                let version = try OfficialFoodVersionRecord
                .filter(Column("official_food_id") == foodId)
                .order(Column("created_at").desc, Column("id").desc)
                .fetchOne(db),
                let nutrients = version.nutrients else {
                return nil
            }
            return IngredientNutritionSnapshot(
                provider: food.provider,
                providerFoodId: food.providerFoodId,
                versionLabel: version.versionLabel,
                basis: version.foodCatalogBasis,
                per100: nutrients,
                nameOriginal: food.nameOriginal,
                sourceUrl: version.sourceUrl,
                capturedAt: capturedAt
            )
        }
    }

    static func parseIdentity(_ entryId: String) -> (provider: String, providerFoodId: String)? {
        let parts = entryId.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let provider = parts[0].uppercased()
        let foodId = String(parts[1])
        guard !foodId.isEmpty else { return nil }
        return (provider, foodId)
    }
}
