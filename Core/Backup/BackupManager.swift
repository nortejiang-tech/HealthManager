import Foundation
import Combine

/// 备份/恢复的门面：位置管理、后台自动导出、恢复执行。
/// App 自身不上传数据——只在用户选择的本地/云端文件夹里写备份包（ADR-003）。
@MainActor
final class BackupManager: ObservableObject {

    @Published private(set) var configuredLocationURL: URL?
    @Published private(set) var lastExportAt: Date?
    @Published private(set) var lastExportError: String?
    @Published private(set) var lastRestoreError: String?
    @Published private(set) var lastRestoreSummary: BackupImportSummary?
    @Published private(set) var isExporting = false
    @Published private(set) var isRestoring = false

    private let database: DatabaseManager
    private let locationStore: BackupLocationStore

    init(
        database: DatabaseManager,
        locationStore: BackupLocationStore = BackupLocationStore()
    ) {
        self.database = database
        self.locationStore = locationStore
        self.configuredLocationURL = locationStore.load()
        self.lastExportAt = locationStore.lastExportAt
    }

    // MARK: - 位置

    /// 用户选定备份文件夹（沙盒外目录需要 security-scoped 权限，随书签保存）。
    func setLocation(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        try locationStore.save(url: url)
        configuredLocationURL = url
    }

    func clearLocation() {
        locationStore.clear()
        configuredLocationURL = nil
    }

    /// 包目录：<location>/HealthManagerBackup/
    func packageURL(for location: URL) -> URL {
        location.appendingPathComponent("HealthManagerBackup", isDirectory: true)
    }

    // MARK: - 导出

    /// 手动「立即备份」。
    func exportNow() async {
        guard let location = configuredLocationURL else {
            lastExportError = "尚未选择备份位置。请先在下方设置备份文件夹。"
            return
        }
        isExporting = true
        defer { isExporting = false }
        let accessing = location.startAccessingSecurityScopedResource()
        defer {
            if accessing { location.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try await BackupExporter(database: database)
                .export(to: packageURL(for: location))
            let now = Date()
            lastExportAt = now
            locationStore.setLastExportAt(now)
            lastExportError = nil
        } catch {
            lastExportError = "备份失败：\(error.localizedDescription)"
            AppLogger.shared.error("Backup export failed: \(error.localizedDescription)")
        }
    }

    /// 退后台时调用：已配置位置则自动导出，未配置则静默跳过。
    func exportIfConfigured() async {
        guard configuredLocationURL != nil else { return }
        await exportNow()
    }

    // MARK: - 恢复

    /// 从用户选择的文件夹恢复（同时兼容选择包目录或其父目录）。
    /// 幂等：只补缺、不覆盖，可重复执行。
    func restore(from pickedURL: URL) async {
        isRestoring = true
        defer { isRestoring = false }
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { pickedURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let summary = try await BackupImporter(database: database)
                .importPackage(from: pickedURL)
            lastRestoreSummary = summary
            lastRestoreError = nil
            AppEnvironment.shared.notifyLocalDataChanged()
        } catch {
            lastRestoreSummary = nil
            lastRestoreError = "恢复失败：\(error.localizedDescription)"
            AppLogger.shared.error("Backup restore failed: \(error.localizedDescription)")
        }
    }
}
