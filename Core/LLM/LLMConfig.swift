import Foundation
import Security

/// LLM provider configuration. OpenAI-compatible Chat Completions endpoint targeting
/// 国内 providers (DeepSeek / Doubao / Qwen / GLM) plus Google Gemini.
///
/// Splits across two stores:
/// - `baseURL`, `visionBaseURL`, `model`, `enabled`, custom presets: `UserDefaults`
/// - API keys: iOS Keychain — one JSON item (`llm.keyStore`) mapping a normalized
///   baseURL → its API key. This lets the text and vision channels use different
///   providers/keys, and remembers each provider's key so it never has to be retyped.
enum LLMConfig {

    private static let defaults = UserDefaults.standard
    private static let baseURLKey = "llm.baseURL"
    private static let visionBaseURLKey = "llm.visionBaseURL"
    private static let textModelKey = "llm.textModel"
    private static let visionModelKey = "llm.visionModel"
    private static let enabledKey = "llm.enabled"
    private static let customPresetsKey = "llm.customPresets"
    private static let migratedFlagKey = "llm.keyStore.migrated.v1"
    private static let keychainService = "com.norte.HealthManager.llm"
    private static let keyStoreAccount = "llm.keyStore"
    private static let legacyKeyAccount = "llm.apiKey"

    /// Preset endpoints with both a text model and a vision model. Either model can be
    /// empty if the provider doesn't ship one in their free tier; user can still type any.
    struct Preset: Identifiable, Hashable, Codable {
        let name: String
        let baseURL: String
        let suggestedTextModel: String
        let suggestedVisionModel: String   // empty string if N/A
        var id: String { name }
    }

    /// Shipped presets. Custom (user-added) ones live in `customPresets`.
    static let builtInPresets: [Preset] = [
        Preset(name: "智谱 GLM（免费）",
               baseURL: "https://open.bigmodel.cn/api/paas/v4",
               suggestedTextModel: "glm-4.7-flash",
               suggestedVisionModel: "glm-4v-flash"),
        Preset(name: "Google Gemini（免费）",
               baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
               suggestedTextModel: "gemini-2.5-flash",
               suggestedVisionModel: "gemini-2.5-flash"),
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
               suggestedVisionModel: ""),
        Preset(name: "Ollama Cloud",
               baseURL: "https://api.ollama.com/v1",
               suggestedTextModel: "gpt-oss:20b",
               suggestedVisionModel: "qwen2.5vl:7b")
    ]

    /// User-added presets, persisted as JSON in UserDefaults.
    static var customPresets: [Preset] {
        get {
            guard let data = defaults.data(forKey: customPresetsKey),
                  let list = try? JSONDecoder().decode([Preset].self, from: data)
            else { return [] }
            return list
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: customPresetsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: customPresetsKey)
            }
        }
    }

    /// Built-in + custom presets. Custom ones appended last.
    static var presets: [Preset] { builtInPresets + customPresets }

    /// Whether a preset id refers to a user-added (deletable) preset.
    static func isCustomPreset(id: String) -> Bool {
        customPresets.contains { $0.id == id }
    }

    /// Add (or replace by name) a custom preset.
    static func addCustomPreset(_ preset: Preset) {
        var list = customPresets
        list.removeAll { $0.id == preset.id }
        list.append(preset)
        customPresets = list
    }

    static func removeCustomPreset(id: String) {
        customPresets = customPresets.filter { $0.id != id }
    }

    static var baseURL: String {
        get { defaults.string(forKey: baseURLKey) ?? "" }
        set { defaults.set(newValue, forKey: baseURLKey) }
    }

    /// Vision endpoint. Empty means "follow text endpoint" for backward compatibility.
    static var visionBaseURL: String {
        get { defaults.string(forKey: visionBaseURLKey) ?? "" }
        set { defaults.set(newValue, forKey: visionBaseURLKey) }
    }

    static var resolvedVisionBaseURL: String {
        let explicit = visionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit.isEmpty ? baseURL : explicit
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
        !baseURL.isEmpty && !textModel.isEmpty && !(textApiKey ?? "").isEmpty
    }

    /// Whether vision-model usage is configured (key + baseURL + visionModel).
    static var isVisionConfigured: Bool {
        !resolvedVisionBaseURL.isEmpty && !visionModel.isEmpty && !(visionApiKey ?? "").isEmpty
    }

    // MARK: - Per-provider API keys

    /// Normalize a base URL so the same provider always maps to one key-store entry.
    static func normalizedBase(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Remembered API key for a given endpoint, or nil if none stored.
    static func apiKey(forBaseURL url: String) -> String? {
        let v = loadKeyStore()[normalizedBase(url)]
        return (v?.isEmpty == false) ? v : nil
    }

    /// Store (or clear, when nil/empty) the API key for a given endpoint.
    static func setApiKey(_ value: String?, forBaseURL url: String) {
        var store = loadKeyStore()
        let key = normalizedBase(url)
        if let value, !value.isEmpty {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
        saveKeyStore(store)
    }

    /// Active text-channel key — the one remembered for the current text endpoint.
    static var textApiKey: String? { apiKey(forBaseURL: baseURL) }

    /// Active vision-channel key — the one remembered for the resolved vision endpoint.
    static var visionApiKey: String? { apiKey(forBaseURL: resolvedVisionBaseURL) }

    /// DEPRECATED single-key accessor — kept so old call sites / tests don't break.
    /// Reads/writes the key for the current text endpoint.
    static var apiKey: String? {
        get { textApiKey }
        set { setApiKey(newValue, forBaseURL: baseURL) }
    }

    // MARK: - Keychain-backed key store

    private static func loadKeyStore() -> [String: String] {
        migrateLegacyKeyIfNeeded()
        return rawLoadKeyStore()
    }

    private static func rawLoadKeyStore() -> [String: String] {
        guard let raw = readKeychain(account: keyStoreAccount),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveKeyStore(_ dict: [String: String]) {
        if dict.isEmpty {
            deleteKeychain(account: keyStoreAccount)
            return
        }
        guard let data = try? JSONEncoder().encode(dict),
              let s = String(data: data, encoding: .utf8) else { return }
        writeKeychain(account: keyStoreAccount, s)
    }

    /// One-shot migration: earlier builds stored a single key under `llm.apiKey`.
    /// Seed it into the new per-endpoint store for both channels, then drop the legacy item.
    private static func migrateLegacyKeyIfNeeded() {
        guard !defaults.bool(forKey: migratedFlagKey) else { return }
        defaults.set(true, forKey: migratedFlagKey)
        guard let legacy = readKeychain(account: legacyKeyAccount), !legacy.isEmpty else { return }
        var store = rawLoadKeyStore()
        let textBase = normalizedBase(baseURL)
        if !textBase.isEmpty, store[textBase] == nil { store[textBase] = legacy }
        let visionBase = normalizedBase(resolvedVisionBaseURL)
        if !visionBase.isEmpty, store[visionBase] == nil { store[visionBase] = legacy }
        saveKeyStore(store)
        deleteKeychain(account: legacyKeyAccount)
    }

    // MARK: - Keychain primitives

    private static func fallbackDefaultsKey(account: String) -> String {
        "llm.kc.fallback.\(account)"
    }

    @discardableResult
    private static func writeKeychain(account: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)   // upsert
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        // Keychain may be unavailable in xctest hosts without proper signing —
        // fall back to UserDefaults so the rest of the app keeps working.
        // (Intentionally less secure; we log so it's visible.)
        AppLogger.shared.error("Keychain write failed (OSStatus=\(status)); falling back to UserDefaults")
        defaults.set(value, forKey: fallbackDefaultsKey(account: account))
        return false
    }

    private static func readKeychain(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
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
        return defaults.string(forKey: fallbackDefaultsKey(account: account))
    }

    @discardableResult
    private static func deleteKeychain(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(q as CFDictionary)
        defaults.removeObject(forKey: fallbackDefaultsKey(account: account))
        return status == errSecSuccess
    }

    /// Wipe baseURL / models / enabled / all remembered keys. Used by Settings 「清除」.
    /// Custom presets are intentionally kept — they're a user-curated address book.
    static func reset() {
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: visionBaseURLKey)
        defaults.removeObject(forKey: textModelKey)
        defaults.removeObject(forKey: visionModelKey)
        defaults.removeObject(forKey: enabledKey)
        saveKeyStore([:])
        deleteKeychain(account: legacyKeyAccount)
    }
}
