import Foundation

/// 备份包中的 App 配置快照（settings.json）。
///
/// 包含：对账阈值、仪表盘卡片布局、AI 非敏感配置（端点/模型/预设/配置档）。
/// 不含 API Key——密钥存 Keychain，绝不出现在明文备份包中。
struct BackupSettings: Codable, Equatable, Sendable {

    // 对账阈值（对应 ReconcilerSettings）
    var reconcileCompletenessThreshold: Double
    var reconcileConflictMinSources: Int
    var reconcileConsecutiveMissingForCritical: Int
    var reconcileDefaultWindowDays: Int

    /// 仪表盘可见卡片 rawValue 列表（对应 DashboardLayoutStore.storageKey，
    /// 以原始 JSON 数组字符串的形式存 UserDefaults）。
    var dashboardVisibleCards: [String]

    // AI 配置（非敏感部分，对应 LLMConfig）
    var llmEnabled: Bool
    var llmBaseURL: String
    var llmVisionBaseURL: String
    var llmTextModel: String
    var llmVisionModel: String
    var llmCustomPresets: [LLMConfig.Preset]
    var llmProfiles: [LLMConfig.Profile]
    var llmActiveProfileName: String?

    // 与 DashboardLayoutStore.storageKey 保持同步。
    static let dashboardLayoutStorageKey = "dashboard.layout.visibleCards.v1"

    /// 从当前 App 状态采集快照。
    static func capture() -> BackupSettings {
        var visibleCards: [String] = []
        if let data = UserDefaults.standard.data(forKey: dashboardLayoutStorageKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            visibleCards = decoded
        }
        return BackupSettings(
            reconcileCompletenessThreshold: ReconcilerSettings.completenessThreshold,
            reconcileConflictMinSources: ReconcilerSettings.conflictMinSources,
            reconcileConsecutiveMissingForCritical: ReconcilerSettings.consecutiveMissingForCritical,
            reconcileDefaultWindowDays: ReconcilerSettings.defaultWindowDays,
            dashboardVisibleCards: visibleCards,
            llmEnabled: LLMConfig.enabled,
            llmBaseURL: LLMConfig.baseURL,
            llmVisionBaseURL: LLMConfig.visionBaseURL,
            llmTextModel: LLMConfig.textModel,
            llmVisionModel: LLMConfig.visionModel,
            llmCustomPresets: LLMConfig.customPresets,
            llmProfiles: LLMConfig.profiles,
            llmActiveProfileName: LLMConfig.activeProfileName
        )
    }

    /// 应用快照到当前 App。
    /// 阈值与布局无条件应用（重装恢复场景，本地还是默认值）；
    /// AI 配置只在本地尚未配置时应用（避免覆盖用户重装后已新设的 AI）。
    func apply() {
        ReconcilerSettings.completenessThreshold = reconcileCompletenessThreshold
        ReconcilerSettings.conflictMinSources = reconcileConflictMinSources
        ReconcilerSettings.consecutiveMissingForCritical = reconcileConsecutiveMissingForCritical
        ReconcilerSettings.defaultWindowDays = reconcileDefaultWindowDays

        if let data = try? JSONEncoder().encode(dashboardVisibleCards) {
            UserDefaults.standard.set(data, forKey: Self.dashboardLayoutStorageKey)
        }

        // enabled 的默认值是 true，不能用来判「未配置」；以端点/模型字段是否为空为准。
        let llmUntouched = LLMConfig.baseURL.isEmpty
            && LLMConfig.textModel.isEmpty
            && LLMConfig.visionBaseURL.isEmpty
            && LLMConfig.visionModel.isEmpty
            && LLMConfig.customPresets.isEmpty
            && LLMConfig.profiles.isEmpty
            && LLMConfig.activeProfileName == nil
        if llmUntouched {
            LLMConfig.enabled = llmEnabled
            LLMConfig.baseURL = llmBaseURL
            LLMConfig.visionBaseURL = llmVisionBaseURL
            LLMConfig.textModel = llmTextModel
            LLMConfig.visionModel = llmVisionModel
            LLMConfig.customPresets = llmCustomPresets
            LLMConfig.profiles = llmProfiles
            LLMConfig.activeProfileName = llmActiveProfileName
        }
    }
}
