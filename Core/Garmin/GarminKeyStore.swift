import Foundation
import Security

/// Device-only secret, excluded from backup/Bridge. No username or web session is needed.
struct GarminKeyStore: GarminCredentialSource {
    private static let service = "com.norte.HealthManager.garmin-personal"
    private let account: String
    init(account: String = "china-api-key") { self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }
    func read() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw GarminAPIError.keyUnavailable }
        return value
    }
    var isConfigured: Bool { (try? read()) != nil }
    func save(_ value: String) throws {
        guard GarminClient.validKey(value) else { throw GarminAPIError.invalidKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new.merge(attributes) { _, b in b }
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw GarminAPIError.keyUnavailable }
        } else if status != errSecSuccess { throw GarminAPIError.keyUnavailable }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GarminAPIError.keyUnavailable }
    }
}
