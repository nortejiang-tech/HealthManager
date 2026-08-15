import XCTest
import GRDB
import CryptoKit
@testable import HealthManager

/// 备份包契约测试（ADR-003）：
/// 导出 → 全新库导入 → 逐表比对；幂等重导；版本/校验/未知文件/未知字段的防御。
final class BackupExportImportTests: XCTestCase {

    private var source: DatabaseManager!
    private var target: DatabaseManager!

    override func setUp() async throws {
        source = DatabaseManager.makeInMemoryForTesting()
        target = DatabaseManager.makeInMemoryForTesting()
    }

    override func tearDown() async throws {
        source = nil
        target = nil
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func insertFixtures(into db: DatabaseManager) throws {
        try db.write { database in
            try database.execute(sql: """
                INSERT INTO meal_records
                  (id, meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g, notes, created_at)
                VALUES (1, 'lunch', 1_700_000_000, 600, 40, 20, 80, '牛油果鸡胸沙拉', 1_700_000_000)
                """)
            try database.execute(sql: """
                INSERT INTO meal_items
                  (id, meal_id, sort_order, name, grams, preparation_state, calories_kcal, protein_g, fat_g, carbs_g, provenance_kind, is_user_edited, created_at, updated_at)
                VALUES (1, 1, 0, '鸡胸肉', 120, 'cooked', 198, 37, 4, 0, 'manual', 1, 1_700_000_000, 1_700_000_000)
                """)
            try database.execute(sql: """
                INSERT INTO medication_plans
                  (id, name, dosage_mg, frequency, reminder_enabled, notes, created_at)
                VALUES (1, '维生素D', 25, 'daily', 1, '早餐后', 1_700_000_000)
                """)
            try database.execute(sql: """
                INSERT INTO medication_logs
                  (id, plan_id, scheduled_at, action, action_at, created_at)
                VALUES (1, 1, 1_700_000_000, 'taken', 1_700_000_100, 1_700_000_100)
                """)
            try database.execute(sql: """
                INSERT INTO activity_metrics_daily (date, step_count, active_energy_kcal, computed_at)
                VALUES ('2026-08-16', 12000, 480, 100)
                """)
            try database.execute(sql: """
                INSERT INTO body_metrics_daily (date, weight_kg, computed_at)
                VALUES ('2026-08-16', 72.5, 100)
                """)
            try database.execute(sql: """
                INSERT INTO source_coverage_daily (date, source_bundle_id, source_name, sample_count, last_seen_at)
                VALUES ('2026-08-16', 'com.apple.health', 'Apple Watch', 320, 100)
                """)
            try database.execute(sql: """
                INSERT INTO data_quality_daily (date, completeness_score, freshness_score, conflict_score, computed_at)
                VALUES ('2026-08-16', 1.0, 0.9, 0.8, 100)
                """)
            try database.execute(sql: """
                INSERT INTO missing_data_alerts (id, date, metric, severity, message, acknowledged, created_at)
                VALUES (1, '2026-08-16', 'sleep', 'warning', '睡眠数据缺失', 0, 100)
                """)
            try database.execute(sql: """
                INSERT INTO daily_summaries (date, summary_text, quality_score, generated_at)
                VALUES ('2026-08-16', '今日摘要', 0.95, 100)
                """)
            try database.execute(sql: """
                INSERT INTO weekly_summaries (week_start_date, summary_text, quality_score, generated_at)
                VALUES ('2026-08-10', '本周摘要', 0.9, 100)
                """)
        }
    }

    func test_roundTrip_exportThenImport_restoresAllTables() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        // 导出
        let exporter = BackupExporter(database: source)
        let manifest = try await exporter.export(to: packageDir)
        XCTAssertEqual(manifest.formatVersion, BackupManifest.currentFormatVersion)
        // 11 张表 + settings.json
        XCTAssertEqual(manifest.files.count, BackupExporter.tables.count + 1)
        XCTAssertEqual(
            manifest.files.map(\.file).sorted(),
            (BackupExporter.tables.map(\.fileName) + [BackupExporter.settingsFileName]).sorted()
        )

        // manifest 可解码且字段一致
        let decoded = try JSONDecoder().decode(
            BackupManifest.self,
            from: Data(contentsOf: packageDir.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(decoded, manifest)

        // README 存在
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: packageDir.appendingPathComponent("README.md").path))

        // 导入到全新库
        let importer = BackupImporter(database: target)
        let summary = try await importer.importPackage(from: packageDir)
        XCTAssertEqual(summary.totalImported, 11) // 11 张表各 1 行
        XCTAssertEqual(summary.totalSkipped, 0)

        // 逐表行数一致 + 关键字段抽查
        try assertRowCounts()
        try assertSpotChecks()
    }

    func test_roundTrip_JSONLinesAreValidJSONObjects() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        _ = try await BackupExporter(database: source).export(to: packageDir)

        let line = try String(
            contentsOf: packageDir.appendingPathComponent("meal_records.jsonl"),
            encoding: .utf8
        ).split(separator: "\n").first
        let object = try XCTUnwrap(line)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any])
        XCTAssertEqual(dict["meal_type"] as? String, "lunch")
        XCTAssertEqual(dict["calories_kcal"] as? Double, 600)
    }

    func test_reimport_isIdempotent_onlyFillsMissing() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        _ = try await BackupExporter(database: source).export(to: packageDir)
        let importer = BackupImporter(database: target)

        let first = try await importer.importPackage(from: packageDir)
        XCTAssertEqual(first.totalImported, 11)

        // 本地已改动的行不被覆盖：只补缺、不覆盖（ADR-003）。
        try target.write { db in
            try db.execute(sql: "UPDATE meal_records SET notes = '本地修改' WHERE id = 1")
        }
        let second = try await importer.importPackage(from: packageDir)
        // 投影表（5 张）幂等重写；用户表（6 张）全部跳过。
        XCTAssertEqual(second.totalImported, 5)
        XCTAssertEqual(second.totalSkipped, 6)
        let notes = try target.read { db in
            try String.fetchOne(db, sql: "SELECT notes FROM meal_records WHERE id = 1")
        }
        XCTAssertEqual(notes, "本地修改")
    }

    func test_import_rejectsUnsupportedFormatVersion() async throws {
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let futureManifest = """
        {
          "formatVersion": 999,
          "appVersion": "99.0",
          "exportedAt": 1,
          "files": []
        }
        """
        try Data(futureManifest.utf8).write(
            to: packageDir.appendingPathComponent("manifest.json"))

        do {
            _ = try await BackupImporter(database: target).importPackage(from: packageDir)
            XCTFail("应当拒绝未知格式版本")
        } catch let error as BackupImportError {
            XCTAssertEqual(error, .unsupportedFormatVersion(999))
        }
    }

    func test_import_rejectsCorruptedFileChecksum() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        _ = try await BackupExporter(database: source).export(to: packageDir)

        // 篡改一个数据文件
        let mealFile = packageDir.appendingPathComponent("meal_records.jsonl")
        var corrupted = try String(contentsOf: mealFile, encoding: .utf8)
        corrupted += "{\"id\": 999}\n"
        try Data(corrupted.utf8).write(to: mealFile)

        do {
            _ = try await BackupImporter(database: target).importPackage(from: packageDir)
            XCTFail("应当拒绝校验失败的文件")
        } catch let error as BackupImportError {
            guard case .checksumMismatch(let file) = error else {
                return XCTFail("期望 checksumMismatch，实际 \(error)")
            }
            XCTAssertEqual(file, "meal_records.jsonl")
        }
    }

    func test_import_ignoresUnknownFilesAndColumns() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        var manifest = try await BackupExporter(database: source).export(to: packageDir)

        // 1) 未知文件（未来版本新增的表）→ 跳过不报错。
        let futureData = Data("{\"x\": 1}\n".utf8)
        let digest = SHA256Digest(futureData)
        var files = manifest.files
        files.append(BackupFileEntry(
            file: "future_table.jsonl",
            recordCount: 1,
            bytes: futureData.count,
            sha256: digest
        ))
        manifest = BackupManifest(
            formatVersion: manifest.formatVersion,
            appVersion: manifest.appVersion,
            exportedAt: manifest.exportedAt,
            files: files
        )
        try Data(futureData).write(
            to: packageDir.appendingPathComponent("future_table.jsonl"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(manifest).write(
            to: packageDir.appendingPathComponent("manifest.json"), options: .atomic)

        // 2) 已知表但行内含未知字段 → 忽略未知列，导入已知列。
        let mealsFile = packageDir.appendingPathComponent("meal_records.jsonl")
        let extraFieldLine = "{\"id\": 2, \"meal_type\": \"dinner\", \"eaten_at\": 1700000001, \"created_at\": 1700000001, \"future_column\": \"ignored\"}\n"
        let original = try String(contentsOf: mealsFile, encoding: .utf8)
        try Data((original + extraFieldLine).utf8).write(to: mealsFile)
        // 重新计算该文件校验和并写回 manifest
        let newData = try Data(contentsOf: mealsFile)
        let newDigest = SHA256Digest(newData)
        files = manifest.files.filter { $0.file != "meal_records.jsonl" }
        files.append(BackupFileEntry(
            file: "meal_records.jsonl",
            recordCount: 2,
            bytes: newData.count,
            sha256: newDigest))
        manifest = BackupManifest(
            formatVersion: manifest.formatVersion,
            appVersion: manifest.appVersion,
            exportedAt: manifest.exportedAt,
            files: files
        )
        try encoder.encode(manifest).write(
            to: packageDir.appendingPathComponent("manifest.json"), options: .atomic)

        let summary = try await BackupImporter(database: target).importPackage(from: packageDir)
        XCTAssertEqual(summary.totalImported, 12) // 11 + 新增的 dinner 行
        let dinnerCount = try target.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meal_records WHERE meal_type = 'dinner'")
        }
        XCTAssertEqual(dinnerCount, 1)
    }

    func test_manifestURL_supportsPackageAndParentFolder() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("HealthManagerBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("manifest.json"))

        XCTAssertEqual(BackupImporter.manifestURL(for: package), package.appendingPathComponent("manifest.json"))
        XCTAssertEqual(BackupImporter.manifestURL(for: root), package.appendingPathComponent("manifest.json"))
    }

    // MARK: - 回归：重装后空投影行不得挡住备份值

    func test_import_replacesEmptyProjectionRows() async throws {
        // 复现真实 bug：重装后启动补算在无原始样本时写下空投影行（date 存在、指标全 nil），
        // 旧逻辑 INSERT OR IGNORE 会跳过备份里的真实值 → 最近 90 天数据丢失。
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }
        _ = try await BackupExporter(database: source).export(to: packageDir)

        try target.write { db in
            try db.execute(sql: """
                INSERT INTO activity_metrics_daily (date, computed_at)
                VALUES ('2026-08-16', 100)
                """)
        }

        let summary = try await BackupImporter(database: target).importPackage(from: packageDir)
        _ = summary

        let row = try target.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT step_count, active_energy_kcal FROM activity_metrics_daily WHERE date = '2026-08-16'"
            )
        }
        XCTAssertEqual(row?["step_count"], 12000)
        XCTAssertEqual(row?["active_energy_kcal"], 480)
    }

    func test_import_userTables_stillNeverOverwriteLocalRows() async throws {
        // 投影表可覆盖；用户创作表（餐食）仍只补缺、不覆盖。
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }
        _ = try await BackupExporter(database: source).export(to: packageDir)

        try target.write { db in
            try db.execute(sql: """
                INSERT INTO meal_records
                  (id, meal_type, eaten_at, calories_kcal, created_at)
                VALUES (1, 'breakfast', 1_700_000_000, 999, 1_700_000_000)
                """)
        }

        _ = try await BackupImporter(database: target).importPackage(from: packageDir)
        let row = try target.read { db in
            try Row.fetchOne(db, sql: "SELECT meal_type, calories_kcal FROM meal_records WHERE id = 1")
        }
        XCTAssertEqual(row?["meal_type"], "breakfast") // 本地值保留
        XCTAssertEqual(row?["calories_kcal"], 999)
    }

    // MARK: - settings.json 回环

    func test_settings_roundTrip_appliesAfterFreshInstall() async throws {
        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        // 模拟用户配置
        ReconcilerSettings.completenessThreshold = 0.5
        ReconcilerSettings.conflictMinSources = 4
        UserDefaults.standard.set(
            try JSONEncoder().encode(["activity", "sleep"]),
            forKey: BackupSettings.dashboardLayoutStorageKey
        )
        LLMConfig.baseURL = "http://192.168.1.10:11434/v1"
        LLMConfig.textModel = "qwen3"
        LLMConfig.enabled = true
        defer {
            ReconcilerSettings.resetToDefaults()
            UserDefaults.standard.removeObject(forKey: BackupSettings.dashboardLayoutStorageKey)
            LLMConfig.baseURL = ""
            LLMConfig.textModel = ""
            LLMConfig.enabled = false
        }
        _ = try await BackupExporter(database: source).export(to: packageDir)

        // 模拟重装：配置回到默认
        ReconcilerSettings.resetToDefaults()
        UserDefaults.standard.removeObject(forKey: BackupSettings.dashboardLayoutStorageKey)
        LLMConfig.baseURL = ""
        LLMConfig.textModel = ""
        LLMConfig.visionBaseURL = ""
        LLMConfig.visionModel = ""
        LLMConfig.customPresets = []
        LLMConfig.profiles = []
        LLMConfig.activeProfileName = nil
        LLMConfig.enabled = false

        _ = try await BackupImporter(database: target).importPackage(from: packageDir)

        XCTAssertEqual(ReconcilerSettings.completenessThreshold, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ReconcilerSettings.conflictMinSources, 4)
        let cardsData = UserDefaults.standard.data(forKey: BackupSettings.dashboardLayoutStorageKey)
        let cards = try XCTUnwrap(cardsData).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        XCTAssertEqual(cards, ["activity", "sleep"])
        XCTAssertEqual(LLMConfig.baseURL, "http://192.168.1.10:11434/v1")
        XCTAssertEqual(LLMConfig.textModel, "qwen3")
        XCTAssertEqual(LLMConfig.enabled, true)
    }

    // MARK: - 位置书签（Keychain，卸载重装后仍有效）

    func test_locationStore_saveLoadClearRoundTrip() throws {
        let store = BackupLocationStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            store.clear()
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertNil(store.load())
        try store.save(url: dir)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.lastPathComponent, dir.lastPathComponent)
        store.clear()
        XCTAssertNil(store.load())
    }

    func test_settings_doNotClobberLocallyConfiguredLLM() async throws {        try insertFixtures(into: source)
        let packageDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: packageDir) }

        LLMConfig.baseURL = "http://old.local/v1"
        LLMConfig.enabled = true
        defer {
            LLMConfig.baseURL = ""
            LLMConfig.enabled = false
        }
        _ = try await BackupExporter(database: source).export(to: packageDir)

        // 重装后用户已新配 AI：恢复不得覆盖。
        LLMConfig.baseURL = "http://new.local/v1"
        LLMConfig.enabled = true
        defer { LLMConfig.baseURL = "" }

        _ = try await BackupImporter(database: target).importPackage(from: packageDir)
        XCTAssertEqual(LLMConfig.baseURL, "http://new.local/v1")
    }

    // MARK: - 断言辅助

    private func assertRowCounts() throws {
        let expected: [String: Int] = [
            "meal_records": 1, "meal_items": 1,
            "medication_plans": 1, "medication_logs": 1,
            "activity_metrics_daily": 1, "body_metrics_daily": 1,
            "source_coverage_daily": 1, "data_quality_daily": 1,
            "missing_data_alerts": 1, "daily_summaries": 1, "weekly_summaries": 1,
        ]
        try target.read { db in
            for (table, count) in expected {
                let actual = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
                XCTAssertEqual(actual, count, "表 \(table) 行数不符")
            }
        }
    }

    private func assertSpotChecks() throws {
        try target.read { db in
            let meal = try Row.fetchOne(db, sql: "SELECT * FROM meal_records WHERE id = 1")
            XCTAssertEqual(meal?["meal_type"], "lunch")
            XCTAssertEqual(meal?["notes"], "牛油果鸡胸沙拉")

            let item = try Row.fetchOne(db, sql: "SELECT * FROM meal_items WHERE id = 1")
            XCTAssertEqual(item?["name"], "鸡胸肉")
            XCTAssertEqual(item?["provenance_kind"], "manual")

            let log = try Row.fetchOne(db, sql: "SELECT * FROM medication_logs WHERE id = 1")
            XCTAssertEqual(log?["action"], "taken")

            let activity = try Row.fetchOne(
                db, sql: "SELECT * FROM activity_metrics_daily WHERE date = '2026-08-16'")
            XCTAssertEqual(activity?["step_count"], 12000)

            let alert = try Row.fetchOne(db, sql: "SELECT * FROM missing_data_alerts WHERE id = 1")
            XCTAssertEqual(alert?["severity"], "warning")
        }
    }
}

/// SHA-256 → hex 字符串（测试里重算校验和用）。
private func SHA256Digest(_ data: Data) -> String {
    var hasher = CryptoKit.SHA256()
    hasher.update(data: data)
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
}
