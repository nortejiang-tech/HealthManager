import Foundation
import GRDB
import CryptoKit

enum BackupImportError: Error, Equatable, LocalizedError {
    case manifestMissing
    case manifestUnreadable(String)
    case unsupportedFormatVersion(Int)
    case checksumMismatch(String)
    case invalidJSON(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "所选文件夹中没有找到 manifest.json（备份包清单）。"
        case .manifestUnreadable(let detail):
            return "备份清单无法读取：\(detail)"
        case .unsupportedFormatVersion(let version):
            return "备份包格式版本 \(version) 高于当前 App 支持的版本，请先升级 App 再恢复。"
        case .checksumMismatch(let file):
            return "备份文件校验失败（可能已损坏）：\(file)"
        case .invalidJSON(let detail):
            return "备份内容不是合法 JSON：\(detail)"
        case .importFailed(let detail):
            return "导入失败：\(detail)"
        }
    }
}

struct BackupImportSummary: Equatable, Sendable {
    /// table → 新增行数
    let importedCounts: [String: Int]
    /// table → 已存在而跳过的行数（只补缺、不覆盖）
    let skippedCounts: [String: Int]

    var totalImported: Int { importedCounts.values.reduce(0, +) }
    var totalSkipped: Int { skippedCounts.values.reduce(0, +) }
}

/// 从备份包恢复。规则（ADR-003）：
/// - manifest 为入口，formatVersion 不高于当前支持版本；
/// - 每文件先校验 SHA-256，再逐行导入；
/// - INSERT OR IGNORE 按主键/唯一键幂等——只补缺、不覆盖，可安全重跑；
/// - 列名白名单取当前数据库实际列，未知字段忽略（向前兼容：旧包→新 App）。
struct BackupImporter {

    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// 用户既可能选备份包目录本身，也可能选其父目录——两者都支持。
    static func manifestURL(for pickedURL: URL) -> URL {
        let direct = pickedURL.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        return pickedURL
            .appendingPathComponent("HealthManagerBackup", isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    func importPackage(from pickedURL: URL) async throws -> BackupImportSummary {
        let manifestURL = Self.manifestURL(for: pickedURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupImportError.manifestMissing
        }

        let manifest: BackupManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw BackupImportError.manifestUnreadable(error.localizedDescription)
        }
        guard BackupManifest.supportedFormatVersions.contains(manifest.formatVersion) else {
            throw BackupImportError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let packageDir = manifestURL.deletingLastPathComponent()
        var importedCounts: [String: Int] = [:]
        var skippedCounts: [String: Int] = [:]

        // 未知文件（未来版本新增的表）→ 记录并跳过，不阻塞导入。
        for entry in manifest.files where BackupExporter.spec(forFileName: entry.file) == nil {
            AppLogger.shared.info(
                "Backup import: skipping unknown file \(entry.file)"
            )
        }

        // 按依赖顺序导入：父表先于子表（meal_records → meal_items、
        // medication_plans → medication_logs），避免外键在导入中途失败。
        let entriesByName = Dictionary(
            uniqueKeysWithValues: manifest.files.map { ($0.file, $0) }
        )
        for spec in BackupExporter.tables {
            guard let entry = entriesByName[spec.fileName] else { continue }
            let fileURL = packageDir.appendingPathComponent(entry.file)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw BackupImportError.importFailed("\(entry.file): \(error.localizedDescription)")
            }
            let digest = SHA256.hash(data: data)
            let actualSHA = digest.map { String(format: "%02x", $0) }.joined()
            guard actualSHA == entry.sha256 else {
                throw BackupImportError.checksumMismatch(entry.file)
            }
            let (imported, skipped) = try await importLines(data: data, spec: spec)
            importedCounts[spec.table] = imported
            skippedCounts[spec.table] = skipped
        }

        // App 配置快照（可选）：存在则校验并应用。
        if let settingsEntry = entriesByName[BackupExporter.settingsFileName] {
            let settingsURL = packageDir.appendingPathComponent(settingsEntry.file)
            let settingsData: Data
            do {
                settingsData = try Data(contentsOf: settingsURL)
            } catch {
                throw BackupImportError.importFailed("\(settingsEntry.file): \(error.localizedDescription)")
            }
            let digest = SHA256.hash(data: settingsData)
            let actualSHA = digest.map { String(format: "%02x", $0) }.joined()
            guard actualSHA == settingsEntry.sha256 else {
                throw BackupImportError.checksumMismatch(settingsEntry.file)
            }
            do {
                let settings = try JSONDecoder().decode(BackupSettings.self, from: settingsData)
                settings.apply()
            } catch {
                throw BackupImportError.invalidJSON(BackupExporter.settingsFileName)
            }
        }

        return BackupImportSummary(
            importedCounts: importedCounts,
            skippedCounts: skippedCounts
        )
    }

    private func importLines(
        data: Data,
        spec: BackupTableSpec
    ) async throws -> (imported: Int, skipped: Int) {
        let columnNames = try await currentColumns(of: spec.table)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        return try await database.asyncWrite { db in
            var imported = 0
            var total = 0
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                      let dict = object as? [String: Any] else {
                    throw BackupImportError.invalidJSON(spec.fileName)
                }
                // 只取当前 schema 中真实存在的列，未知字段忽略。
                let columns = dict.keys
                    .filter { columnNames.contains($0) }
                    .sorted()
                guard !columns.isEmpty else { continue }
                let columnList = columns.map { "\"\($0)\"" }.joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                let arguments: [DatabaseValueConvertible?] = columns.map {
                    Self.argumentValue(dict[$0])
                }
                let verb = spec.replaceOnConflict ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
                try db.execute(
                    sql: "\(verb) INTO \(spec.table) (\(columnList)) VALUES (\(placeholders))",
                    arguments: StatementArguments(arguments)
                )
                let inserted = db.changesCount
                imported += inserted
                total += 1
            }
            return (imported, total - imported)
        }
    }

    private func currentColumns(of table: String) async throws -> Set<String> {
        try await database.asyncRead { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
            var names = Set<String>()
            for row in rows {
                if let name: String = row["name"] {
                    names.insert(name)
                }
            }
            return names
        }
    }

    /// JSON 值 → GRDB 参数。NSNull → nil；CFBoolean → Bool；
    /// 整数值 → Int64，其余数值 → Double；字符串原样。
    static func argumentValue(_ value: Any?) -> DatabaseValueConvertible? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let double = number.doubleValue
            if double.rounded() == double,
               double >= Double(Int64.min),
               double <= Double(Int64.max) {
                return Int64(double)
            }
            return double
        }
        return nil
    }
}
