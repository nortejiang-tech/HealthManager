import Foundation
import Security

/// LLM provider configuration. OpenAI-compatible Chat Completions endpoint targeting
/// 国内 providers (DeepSeek / Doubao / Qwen / etc.).
///
/// Splits across two stores:
/// - `baseURL`, `model`, `enabled`: `UserDefaults` (not secret, easy to inspect)
/// - `apiKey`: iOS Keychain (`kSecClassGenericPassword`, item account = `llm.apiKey`)
///
/// `enabled` defaults **on** per user preference — but if key is missing, the LLM call
/// is silently skipped and the local summary renders. Configuration UI nudges the user
/// to fill in the key once.
enum LLMConfig {

    private static let defaults = UserDefaults.standard
    private static let baseURLKey = "llm.baseURL"
    private static let textModelKey = "llm.textModel"
    private static let visionModelKey = "llm.visionModel"
    private static let enabledKey = "llm.enabled"
    private static let keychainService = "com.norte.HealthManager.llm"
    private static let keychainAccount = "llm.apiKey"

    /// Preset endpoints with both a text model and a vision model. Either can be empty
    /// if the provider doesn't ship one in their free tier; user can still type any model.
    struct Preset: Identifiable, Hashable {
        let name: String
        let baseURL: String
        let suggestedTextModel: String
        let suggestedVisionModel: String   // empty string if N/A
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "智谱 GLM（免费）",
               baseURL: "https://open.bigmodel.cn/api/paas/v4",
               suggestedTextModel: "glm-4.7-flash",
               suggestedVisionModel: "glm-4v-flash"),
        Preset(name: "硅基流动 SiliconFlow",
               baseURL: "https://api.siliconflow.cn/v1",
               suggestedTextModel: "Qwen/Qwen2.5-7B-Instruct",
               suggestedVisionModel: "Qwen/Qwen2-VL-7B-Instruct"),
        Preset(name: "通义千问 / Qwen",
               baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
               suggestedTextModel: "qwen-plus",
               suggestedVisionModel: "qwen-vl-max-latest"),
        Preset(name: "豆包 / Doubao",
               baseURL: "https://ark.cn-beijing.volces.com/api/v3",
               suggestedTextModel: "doubao-1.5-pro-32k",
               suggestedVisionModel: "doubao-1.5-vision-pro-32k"),
        Preset(name: "Moonshot",
               baseURL: "https://api.moonshot.cn/v1",
               suggestedTextModel: "moonshot-v1-8k",
               suggestedVisionModel: "moonshot-v1-8k-vision-preview"),
        Preset(name: "DeepSeek",
               baseURL: "https://api.deepseek.com/v1",
               suggestedTextModel: "deepseek-chat",
               suggestedVisionModel: "")
    ]

    static var baseURL: String {
        get { defaults.string(forKey: baseURLKey) ?? "" }
        set { defaults.set(newValue, forKey: baseURLKey) }
    }

    /// Text-only model for daily / weekly summary commentary.
    static var textModel: String {
        get { defaults.string(forKey: textModelKey) ?? "" }
        set { defaults.set(newValue, forKey: textModelKey) }
    }

    /// Vision-capable model for meal photo nutrition estimation.
    /// Optional — feature is disabled when empty.
    static var visionModel: String {
        get { defaults.string(forKey: visionModelKey) ?? "" }
        set { defaults.set(newValue, forKey: visionModelKey) }
    }

    /// DEPRECATED — kept so old call sites don't break. Maps to textModel.
    static var model: String {
        get { textModel }
        set { textModel = newValue }
    }

    /// Defaults to **true** (opt-out) per user preference. When true but key/url missing,
    /// callers should fall back to the local summary without prompting.
    static var enabled: Bool {
        get {
            if let v = defaults.object(forKey: enabledKey) as? Bool { return v }
            return true
        }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Whether the basic text-model triple is filled (key + baseURL + textModel).
    static var isConfigured: Bool {
        !baseURL.isEmpty && !textModel.isEmpty && !(apiKey ?? "").isEmpty
    }

    /// Whether vision-model usage is configured (key + baseURL + visionModel).
    static var isVisionConfigured: Bool {
        !baseURL.isEmpty && !visionModel.isEmpty && !(apiKey ?? "").isEmpty
    }

    // MARK: - Keychain-backed apiKey

    static var apiKey: String? {
        get { readKey() }
        set {
            if let v = newValue, !v.isEmpty {
                writeKey(v)
            } else {
                deleteKey()
            }
        }
    }

    @discardableResult
    private static func writeKey(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(q as CFDictionary)   // upsert
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        // Keychain may be unavailable in xctest hosts without proper signing —
        // fall back to UserDefaults so the rest of the app keeps working.
        // (This is intentionally less secure; the privacy-conscious path is the
        // Keychain branch above. We log so it's visible.)
        AppLogger.shared.error("Keychain write failed (OSStatus=\(status)); falling back to UserDefaults")
        defaults.set(value, forKey: "llm.apiKey.fallback")
        return false
    }

    private static func readKey() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Fallback path used when Keychain access failed at write time.
        return defaults.string(forKey: "llm.apiKey.fallback")
    }

    @discardableResult
    private static func deleteKey() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(q as CFDictionary)
        defaults.removeObject(forKey: "llm.apiKey.fallback")
        return status == errSecSuccess
    }

    /// Wipe baseURL / model / enabled / key. Used by Settings 「重置」.
    static func reset() {
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: textModelKey)
        defaults.removeObject(forKey: visionModelKey)
        defaults.removeObject(forKey: enabledKey)
        deleteKey()
    }
}
