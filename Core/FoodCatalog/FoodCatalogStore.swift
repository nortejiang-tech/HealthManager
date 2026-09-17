import Foundation

/// 加载并查询内置官方营养目录。
///
/// 目录随 App 打包（Bundle resource），查询完全离线；只有「加入饮食」的保存动作
/// 才走既有写链路——浏览、搜索、换算都不写库、不触发 HealthKit、不发起 AI 请求。
final class FoodCatalogStore: @unchecked Sendable {

    /// 目录资源文件名。换包时同目录新增 v2 文件并迁移加载逻辑，不覆写 v1。
    static let resourceFileName = "food_catalog_v1"

    let catalog: FoodCatalog

    /// App 内共享实例；资源缺失属于打包错误，直接抛出而非静默降级。
    static func makeDefault() throws -> FoodCatalogStore {
        try FoodCatalogStore(bundle: .main)
    }

    convenience init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: Self.resourceFileName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw FoodCatalogError.resourceMissing(Self.resourceFileName)
        }
        try self.init(data: data)
    }

    init(data: Data) throws {
        let decoder = JSONDecoder()
        do {
            catalog = try decoder.decode(FoodCatalog.self, from: data)
        } catch {
            throw FoodCatalogError.decodeFailed(error.localizedDescription)
        }
        guard !catalog.entries.isEmpty else {
            throw FoodCatalogError.emptyCatalog
        }
        // 下载失败/资源损坏时不得把空包当成功更新（docs/food-catalog/README.md）。
        guard !catalog.entries.contains(where: { $0.id.isEmpty || $0.source.isEmpty }) else {
            throw FoodCatalogError.corruptEntry
        }
    }

    /// 按搜索词 + 分类过滤。搜索覆盖中文名、已审核别名与原文名（大小写不敏感）；
    /// 原文名始终保留在条目上，供详情核对。
    func search(query: String, category: FoodCatalogCategory?) -> [FoodCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.entries.filter { entry in
            if let category, entry.category != category { return false }
            guard !trimmed.isEmpty else { return true }
            if entry.nameZh.lowercased().contains(trimmed) { return true }
            if entry.nameOriginal.lowercased().contains(trimmed) { return true }
            return entry.aliases.contains { $0.lowercased().contains(trimmed) }
        }
    }

    func entry(id: String) -> FoodCatalogEntry? {
        catalog.entries.first { $0.id == id }
    }
}

enum FoodCatalogError: Error, Equatable, LocalizedError {
    case resourceMissing(String)
    case decodeFailed(String)
    case emptyCatalog
    case corruptEntry

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "内置营养目录缺失：\(name)"
        case .decodeFailed(let detail):
            return "内置营养目录无法解析：\(detail)"
        case .emptyCatalog:
            return "内置营养目录为空（可能下载/打包失败）"
        case .corruptEntry:
            return "内置营养目录存在损坏条目"
        }
    }
}
