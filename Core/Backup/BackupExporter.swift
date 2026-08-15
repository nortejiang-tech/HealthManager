import Foundation
import GRDB
import CryptoKit

enum BackupExportError: Error, Equatable, LocalizedError {
    case folderUnavailable(String)
    case tableUnavailable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path):
            return "备份文件夹不可用：\(path)"
        case .tableUnavailable(let table):
            return "备份表不可用：\(table)"
        case .writeFailed(let detail):
            return "备份写入失败：\(detail)"
        }
    }
}

/// 备份包表清单。只导出「解析后数据」（ADR-003）：
/// 不含 health_samples_raw / sync_jobs / backfill_report / sync_anchors。
///
/// `replaceOnConflict`：投影表（由 raw 数据派生）恢复时用 INSERT OR REPLACE——
/// 否则重装后启动补算写入的空投影行会挡住备份值（只补缺会跳过它们）；
/// 用户创作表（餐食/用药/摘要）保持 INSERT OR IGNORE，只补缺、不覆盖。
struct BackupTableSpec: Equatable, Sendable {
    let table: String
    let fileName: String
    let orderBy: String
    let replaceOnConflict: Bool
}

/// 把解析后数据表导出为版本化 JSONL 备份包。
/// 目录结构：<location>/HealthManagerBackup/{manifest.json, *.jsonl, settings.json, README.md}
struct BackupExporter {

    static let tables: [BackupTableSpec] = [
        .init(table: "meal_records", fileName: "meal_records.jsonl", orderBy: "id", replaceOnConflict: false),
        .init(table: "meal_items", fileName: "meal_items.jsonl", orderBy: "id", replaceOnConflict: false),
        .init(table: "medication_plans", fileName: "medication_plans.jsonl", orderBy: "id", replaceOnConflict: false),
        .init(table: "medication_logs", fileName: "medication_logs.jsonl", orderBy: "id", replaceOnConflict: false),
        .init(table: "activity_metrics_daily", fileName: "activity_metrics_daily.jsonl", orderBy: "date", replaceOnConflict: true),
        .init(table: "body_metrics_daily", fileName: "body_metrics_daily.jsonl", orderBy: "date", replaceOnConflict: true),
        .init(table: "source_coverage_daily", fileName: "source_coverage_daily.jsonl", orderBy: "date, source_bundle_id", replaceOnConflict: true),
        .init(table: "data_quality_daily", fileName: "data_quality_daily.jsonl", orderBy: "date", replaceOnConflict: true),
        .init(table: "missing_data_alerts", fileName: "missing_data_alerts.jsonl", orderBy: "id", replaceOnConflict: true),
        .init(table: "daily_summaries", fileName: "daily_summaries.jsonl", orderBy: "date", replaceOnConflict: false),
        .init(table: "weekly_summaries", fileName: "weekly_summaries.jsonl", orderBy: "week_start_date", replaceOnConflict: false),
    ]

    static let settingsFileName = "settings.json"

    /// fileName → spec 的白名单（导入侧也用同一份）。
    static func spec(forFileName fileName: String) -> BackupTableSpec? {
        tables.first { $0.fileName == fileName }
    }

    static let readmeText = """
    # HealthManager 备份包

    本目录由 HealthManager 自动生成，供外部工具（如电脑上的 agent）读取。

    - `manifest.json`：格式版本、App 版本、导出时间、每文件记录数、SHA-256 校验和。
    - `*.jsonl`：每行一条 JSON 记录，字段名与 `docs/export-schema.md` 一致。
    - 字段只增不改：新版本只会追加字段，不会改名或删除已有字段。
    - 此备份包不包含照片与 Apple 健康原始样本；原始健康数据由 Apple 健康自身同步。

    导入（恢复）由 HealthManager 的引导页或设置页完成，重复导入安全（只补缺、不覆盖）。
    """

    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// 把全部表导出到包目录（创建目录、逐表写 JSONL、最后写 manifest 与 README）。
    /// manifest 是包的「提交点」：它最后写入，导入侧以它为入口并校验各文件。
    func export(to packageURL: URL) async throws -> BackupManifest {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        } catch {
            throw BackupExportError.folderUnavailable(packageURL.path)
        }

        var entries: [BackupFileEntry] = []
        entries.reserveCapacity(Self.tables.count + 1)
        for spec in Self.tables {
            entries.append(try await exportTable(spec, to: packageURL))
        }
        // App 配置快照（对账阈值 / 卡片布局 / AI 非敏感配置；不含 API Key）。
        entries.append(try exportSettings(to: packageURL))

        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            appVersion: Self.appVersion,
            exportedAt: Int64(Date().timeIntervalSince1970),
            files: entries.sorted { $0.file < $1.file }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: packageURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data(Self.readmeText.utf8).write(
            to: packageURL.appendingPathComponent("README.md"),
            options: .atomic
        )
        return manifest
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func exportSettings(to packageURL: URL) throws -> BackupFileEntry {
        let settings = BackupSettings.capture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(settings)
        let target = packageURL.appendingPathComponent(Self.settingsFileName)
        try data.write(to: target, options: .atomic)
        let digest = SHA256.hash(data: data)
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()
        return BackupFileEntry(
            file: Self.settingsFileName,
            recordCount: 1,
            bytes: data.count,
            sha256: sha256
        )
    }

    private func exportTable(
        _ spec: BackupTableSpec,
        to packageURL: URL
    ) async throws -> BackupFileEntry {
        // Row 序列化全部在 asyncRead 闭包内完成，只把 Sendable 的字符串带出来。
        let lines: [String]
        do {
            lines = try await database.asyncRead { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM \(spec.table) ORDER BY \(spec.orderBy)"
                )
                return try rows.map { row in
                    let dict = Self.jsonSafeObject(row: row)
                    let data = try JSONSerialization.data(
                        withJSONObject: dict,
                        options: [.sortedKeys]
                    )
                    return String(decoding: data, as: UTF8.self)
                }
            }
        } catch {
            throw BackupExportError.tableUnavailable(spec.table)
        }

        var content = lines.joined(separator: "\n")
        if !lines.isEmpty { content.append("\n") }
        let contentData = Data(content.utf8)

        let target = packageURL.appendingPathComponent(spec.fileName)
        do {
            try contentData.write(to: target, options: .atomic)
        } catch {
            throw BackupExportError.writeFailed("\(spec.fileName): \(error.localizedDescription)")
        }

        let digest = SHA256.hash(data: contentData)
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()
        return BackupFileEntry(
            file: spec.fileName,
            recordCount: lines.count,
            bytes: contentData.count,
            sha256: sha256
        )
    }

    /// GRDB Row → JSON 安全字典（字段名 = 数据库列名；Int64/Double/String/Bool/null）。
    static func jsonSafeObject(row: Row) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict.reserveCapacity(row.count)
        for (column, value) in row {
            dict[column] = jsonValue(value)
        }
        return dict
    }

    static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null:
            return NSNull()
        case .int64(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .blob(let data):
            return data.base64EncodedString()
        }
    }
}
