import Foundation
import Combine
import GRDB
import Security
import UIKit

@MainActor
final class HealthBridgeManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "尚未开启"
    @Published private(set) var locationName = "未选择"
    @Published private(set) var lastError: String?
    @Published var historyStart: Date
    private let database: DatabaseManager
    private var location: URL?
    private var debounce: Task<Void,Never>?
    private let defaults = UserDefaults.standard
    private static let bookmarkAccount = "bridge.locationBookmark"
    private static let datasetAccount = "bridge.dataset"

    init(database: DatabaseManager) {
        self.database = database
        historyStart = UserDefaults.standard.object(forKey:"bridge.historyStart") as? Date
            ?? Calendar.current.date(byAdding:.year,value:-1,to:Date())!
        enabled = (try? database.read { try BridgeSource.enabled($0) }) ?? false
        if let data = Self.readKey(Self.bookmarkAccount) {
            var stale = false
            location = try? URL(resolvingBookmarkData:data,options:[],relativeTo:nil,bookmarkDataIsStale:&stale)
            if stale { location = nil; lastError = "同步目录授权已失效，请重新选择" }
        }
        locationName = location?.lastPathComponent ?? "未选择"
        // Dataset identity survives an App reinstall; a new epoch prevents integer-ID collisions.
        do {
            if let data = Self.readKey(Self.datasetAccount), let id = String(data:data,encoding:.utf8), BridgeWire.validID(id) {
                try database.write { try $0.execute(sql:"UPDATE bridge_state SET dataset=? WHERE id=1",arguments:[id]) }
            } else {
                let id = try database.read { try String.fetchOne($0,sql:"SELECT dataset FROM bridge_state WHERE id=1")! }
                try Self.saveKey(Data(id.utf8),Self.datasetAccount)
            }
        } catch { lastError = "无法保存同步数据源身份" }
        status = enabled ? "等待同步或接收回执" : "尚未开启"
    }
    func selectFolder(_ picked: URL) throws {
        guard !isBusy else { throw BridgeError.invalid("请等待当前同步结束") }
        let access = picked.startAccessingSecurityScopedResource(); defer { if access { picked.stopAccessingSecurityScopedResource() } }
        let data = try picked.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
        try Self.saveKey(data,Self.bookmarkAccount)
        // A new directory may not contain the earlier sequence: always start a fresh snapshot.
        try database.write { try BridgeSource.reset($0) }
        location=picked;locationName=picked.lastPathComponent;lastError=nil
    }
    func setEnabled(_ value: Bool) {
        guard !isBusy else { return }
        do {
            if value && location == nil { throw BridgeError.invalid("请先选择 iCloud Drive 中的 Health manager 文件夹") }
            try database.write { try BridgeSource.setEnabled(value,db:$0) }
            enabled=value;status=value ? "等待首次历史采集与同步" : "已停用，已有副本保留";lastError=nil
            if value { defaults.set(historyStart,forKey:"bridge.historyStart") }
        } catch { lastError=error.localizedDescription }
    }
    func rebuild() async {
        guard !isBusy else { return }
        do { try database.write { try BridgeSource.reset($0) }; await exportIfConfigured() }
        catch { lastError=error.localizedDescription }
    }
    func captureAndSync(syncEngine: SyncEngine) async {
        guard enabled, !isBusy, !syncEngine.isBusy else { return }
        // Physical HealthKit backfill precedes initial publication; failed types stay explicitly pending.
        isBusy=true;status="正在从 Apple 健康回补历史…"
        if let previous = try? database.read({ try Double.fetchOne($0,sql:"SELECT history_start FROM bridge_state WHERE id=1") }) {
            historyStart = min(historyStart, Date(timeIntervalSince1970:previous))
        }
        defaults.set(historyStart,forKey:"bridge.historyStart")
        let days = max(1,Calendar.current.dateComponents([.day],from:historyStart,to:Date()).day!+1)
        await syncEngine.runBackfill(days:days)
        isBusy=false
        guard syncEngine.lastResult?.succeeded == true else { lastError="历史采集未完整完成，请在同步中心检查后重试";return }
        do { try database.write { try BridgeSource.reset($0) } }
        catch { lastError=error.localizedDescription;return }
        await exportIfConfigured()
    }
    func scheduleExport() {
        guard enabled else { return }
        debounce?.cancel()
        debounce=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:2_000_000_000); await self?.exportIfConfigured() } catch { }
        }
    }
    func exportIfConfigured() async {
        guard enabled, !isBusy else { return }
        guard let location else { lastError="请重新选择同步文件夹";return }
        isBusy=true;defer { isBusy=false }
        let access=location.startAccessingSecurityScopedResource();defer { if access { location.stopAccessingSecurityScopedResource() } }
        let root = location.lastPathComponent == "HealthBridgeSync" ? location : location.appendingPathComponent("HealthBridgeSync",isDirectory:true)
        let pool=database.pool;let since=historyStart
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"HealthBridge publication") {
            // Durable outbox makes OS interruption replayable; no success is fabricated here.
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask);backgroundTask = .invalid }
        }
        defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }
        do {
            status="正在生成同步数据…"
            let publish = try await Task.detached(priority:.utility) {
                // One bounded delta per pass; subsequent foreground/background events drain remaining work.
                try pool.write { try BridgeSource.prepare($0,historyStart:since) }
                return try BridgeSource.publishPass(pool:pool,root:root)
            }.value
            status = publish.status
            let remaining = try database.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM bridge_changes") ?? 0 }
            if remaining > 0 { status += "；仍有 \(remaining) 项变更待下次处理" }
            if remaining > 0 || publish.shouldContinueImmediately { scheduleExport() }
            lastError=nil
        } catch { lastError=error.localizedDescription;status="同步待重试，已入库副本不受影响" }
    }
    private static func keyQuery(_ account: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.norte.HealthManager",kSecAttrAccount as String:account]
    }
    private static func readKey(_ account: String) -> Data? {
        var q=keyQuery(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item: CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess else { return nil };return item as? Data
    }
    private static func saveKey(_ data: Data, _ account: String) throws {
        let q=keyQuery(account)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add=q;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else { throw BridgeError.invalid("Keychain 写入失败") }
        } else if status != errSecSuccess { throw BridgeError.invalid("Keychain 更新失败") }
    }
}
