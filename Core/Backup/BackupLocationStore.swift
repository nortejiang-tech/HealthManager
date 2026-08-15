import Foundation
import Security

/// 备份位置（用户自选文件夹）的安全书签持久化。
///
/// 书签存 Keychain 而非 UserDefaults：Keychain 在 App 卸载后依然保留
/// （同一 Bundle ID + Team 重装后仍可读到），因此重装后无需重新选择文件夹。
/// 若系统使书签失效（iCloud 路径变化等），读取返回 nil，用户重新选择即可。
final class BackupLocationStore {
    static let keychainService = "com.norte.HealthManager"
    static let bookmarkAccount = "backup.locationBookmark"
    static let lastExportAtKey = "backup.lastExportAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var query = Self.baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "BackupLocationStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败（\(status)）"]
            )
        }
    }

    func load() -> URL? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    func clear() {
        SecItemDelete(Self.baseQuery as CFDictionary)
    }

    var lastExportAt: Date? {
        defaults.object(forKey: Self.lastExportAtKey) as? Date
    }

    func setLastExportAt(_ date: Date) {
        defaults.set(date, forKey: Self.lastExportAtKey)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: bookmarkAccount,
        ]
    }
}
