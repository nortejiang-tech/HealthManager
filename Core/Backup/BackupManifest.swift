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
    /// v2（ADR-004 §2.5）：个人配方/映射三文件。
    /// v3（ADR-005）：新增官方身份/资料版本/个人参考表三文件（含移除状态与
    /// 配方原料完整快照）。旧 App 遇更高版本按 ADR-003 既有策略明确拒绝。
    static let currentFormatVersion = 3
    static let supportedFormatVersions = 1...currentFormatVersion

    let formatVersion: Int
    let appVersion: String
    let exportedAt: Int64
    let files: [BackupFileEntry]
}
