import Foundation

/// 备份包 manifest：schema 版本、App 版本、导出时间与每文件的记录数/校验和。
/// 契约见 docs/adr/ADR-003-backup-package-export-restore.md。
struct BackupFileEntry: Codable, Equatable, Sendable {
    let file: String
    let recordCount: Int
    let bytes: Int
    let sha256: String
}

struct BackupManifest: Codable, Equatable, Sendable {
    /// 当前导出格式版本。格式只增不改（字段名永不改名/删除，只追加）。
    /// v2（ADR-004 §2.5）：新增个人配方/映射三文件 personal_recipes /
    /// personal_recipe_versions / personal_foods；旧 App（supported 1...1）遇 v2
    /// 按 ADR-003 既有策略明确拒绝，不静默丢数据。
    static let currentFormatVersion = 2
    static let supportedFormatVersions = 1...currentFormatVersion

    let formatVersion: Int
    let appVersion: String
    let exportedAt: Int64
    let files: [BackupFileEntry]
}
