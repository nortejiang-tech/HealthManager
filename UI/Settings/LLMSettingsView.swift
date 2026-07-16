import SwiftUI
import UIKit

/// Configure the LLM endpoints that power AI commentary (text) and meal-photo
/// nutrition estimation (vision).
///
/// Text and vision are independent channels: each has its own base URL, model, and
/// API key, so they can point at different providers. Keys are remembered per
/// provider (keyed by base URL) in the Keychain — switching back to a provider
/// auto-refills its key. Presets can be applied to either channel; users can also
/// add their own providers to the list.
struct LLMSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var enabled: Bool = LLMConfig.enabled
    @State private var baseURL: String = LLMConfig.baseURL
    @State private var textModel: String = LLMConfig.textModel
    @State private var textKey: String = LLMConfig.textApiKey ?? ""
    @State private var visionBaseURL: String = LLMConfig.visionBaseURL.isEmpty ? LLMConfig.baseURL : LLMConfig.visionBaseURL
    @State private var visionModel: String = LLMConfig.visionModel
    @State private var visionKey: String = LLMConfig.visionApiKey ?? ""

    @State private var presets: [LLMConfig.Preset] = LLMConfig.presets
    @State private var profiles: [LLMConfig.Profile] = LLMConfig.profiles
    @State private var activeProfileName: String? = LLMConfig.activeProfileName
    @State private var showingAddProvider: Bool = false
    @State private var showingResetConfirm: Bool = false
    @State private var showingSaveProfile: Bool = false
    @State private var newProfileName: String = ""

    @State private var testing: Bool = false
    @State private var testResult: String?
    @State private var testFailed: Bool = false
    @State private var testingVision: Bool = false
    @State private var visionTestResult: String?
    @State private var visionTestFailed: Bool = false

    var body: some View {
        Form {
            Section {
                HMDecisionLens(
                    title: "两条 AI 通道，各自有外发边界",
                    text: "日报 / 周报评注只发送本地聚合摘要文本；餐食照片分析只发送你在编辑器中主动选择的图片。两条通道可以使用不同的接口、模型和 Key。",
                    tone: .estimate,
                    systemImage: "sparkles"
                )
            }

            Section {
                Toggle("启用可选 AI 功能", isOn: $enabled)
            } header: {
                Text("总开关")
            } footer: {
                Text("关闭后本地摘要、餐食手工编辑和保存仍可使用；不会自动请求任何模型服务。")
            }

            profileSection

            Section {
                HMEvidenceTag(
                    tone: textChannelReady ? .estimate : .actionRequired,
                    text: textChannelReady ? "文本评注通道已填写" : "文本评注通道未完成",
                    systemImage: "doc.text"
                )
                Text("发送内容：本机已生成的日报 / 周报聚合摘要文本；不发送原始样本、设备 ID 或来源明细。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Base URL（如 https://open.bigmodel.cn/api/paas/v4）", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                TextField("文本模型（用于日报/周报）", text: $textModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                SecureField("文本接口 API Key", text: $textKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())

                keyStatus(baseURL: baseURL, key: textKey)

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if testing {
                            ProgressView().controlSize(.small)
                        }
                        Label(testing ? "测试中…" : "测试文本模型连接", systemImage: "link")
                    }
                }
                .disabled(testing || !textChannelReady)

                if let result = testResult {
                    HMEditorCallout(
                        title: testFailed ? "文本连接测试失败" : "文本连接测试通过",
                        message: testFailed ? "表单内容和已保存配置均未被覆盖。" : "结果只证明当前文本接口请求成功，不代表照片通道可用。",
                        tone: testFailed ? .actionRequired : .confirmed,
                        systemImage: testFailed ? "xmark.octagon" : "checkmark.seal",
                        detail: result
                    )
                }
            } header: {
                Text("A · 日报 / 周报评注")
            }

            Section {
                HMEvidenceTag(
                    tone: visionChannelReady ? .estimate : .actionRequired,
                    text: visionChannelReady ? "餐食照片通道已填写" : "餐食照片通道未完成",
                    systemImage: "photo"
                )
                Text("发送内容：仅限你在餐食编辑器中主动选择并发起分析的图片；不会访问或上传整个照片库。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Vision Base URL（可与文本不同接口）", text: $visionBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                TextField("视觉模型（用于饮食拍照分析，可留空）", text: $visionModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                SecureField("图像接口 API Key", text: $visionKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                keyStatus(baseURL: effectiveVisionBaseURL, key: visionKey)

                Button {
                    Task { await testVisionConnection() }
                } label: {
                    HStack {
                        if testingVision {
                            ProgressView().controlSize(.small)
                        }
                        Label(testingVision ? "测试中…" : "测试照片模型连接", systemImage: "photo.badge.checkmark")
                    }
                }
                .disabled(testingVision || !visionChannelReady)

                if let visionTestResult {
                    HMEditorCallout(
                        title: visionTestFailed ? "照片连接测试失败" : "照片连接测试通过",
                        message: visionTestFailed
                            ? "表单内容和已保存配置均未被覆盖。"
                            : "结果证明当前接口接收了图像请求；不代表具体餐食估算一定准确。",
                        tone: visionTestFailed ? .actionRequired : .confirmed,
                        systemImage: visionTestFailed ? "xmark.octagon" : "checkmark.seal",
                        detail: visionTestResult
                    )
                }
            } header: {
                Text("B · 餐食照片分析")
            } footer: {
                Text("连接测试只发送 App 内生成的中性测试图和“仅回复 OK”指令，不包含照片库、餐食或健康数据。真实餐食估算仍只在编辑器中由你主动发起。")
            }

            Section {
                HMEditorCallout(
                    title: "Key 与配置分开保存",
                    message: "API Key 存在系统 Keychain，并按接口地址记忆；数据库快照、兼容接口和 Profile 都不包含 Key。",
                    tone: .confirmed,
                    systemImage: "key.fill"
                )
            }

            presetSection

            Section {
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label("清除所有 LLM 配置", systemImage: "trash")
                }
                .tint(HMColors.actionRequired)
            } footer: {
                Text("文本通道只发送本机聚合后的日报 / 周报；照片通道只发送你主动选择并发起分析的图片。不会自动上传原始 HealthKit 样本、设备 ID 或整个照片库。Key 存储在 iOS Keychain，不随 DB 导出。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("AI 功能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    persist()
                    dismiss()
                }
            }
        }
        .onChange(of: baseURL) { _, newValue in
            if let remembered = LLMConfig.apiKey(forBaseURL: newValue) { textKey = remembered }
            activeProfileName = nil  // any hand-edit drops the active-profile marker
        }
        .onChange(of: visionBaseURL) { _, newValue in
            if let remembered = LLMConfig.apiKey(forBaseURL: newValue) { visionKey = remembered }
            activeProfileName = nil
        }
        .onChange(of: textModel) { _, _ in activeProfileName = nil }
        .onChange(of: visionModel) { _, _ in activeProfileName = nil }
        .sheet(isPresented: $showingAddProvider) {
            AddProviderView { preset in
                LLMConfig.addCustomPreset(preset)
                presets = LLMConfig.presets
            }
        }
        .sheet(isPresented: $showingSaveProfile) {
            saveProfileSheet
        }
        .confirmationDialog(
            "清除全部 LLM 配置？",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                LLMConfig.reset()
                enabled = LLMConfig.enabled
                textModel = ""
                visionModel = ""
                baseURL = ""
                visionBaseURL = ""
                textKey = ""
                visionKey = ""
                testResult = nil
                visionTestResult = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var textChannelReady: Bool {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = textKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedBase.isEmpty
            && !trimmedModel.isEmpty
            && (!trimmedKey.isEmpty || LLMConfig.isLocalHost(trimmedBase))
    }

    private var effectiveVisionBaseURL: String {
        let vision = visionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return vision.isEmpty ? baseURL.trimmingCharacters(in: .whitespacesAndNewlines) : vision
    }

    private var visionChannelReady: Bool {
        let model = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = visionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !effectiveVisionBaseURL.isEmpty
            && !model.isEmpty
            && (!key.isEmpty || LLMConfig.isLocalHost(effectiveVisionBaseURL))
    }

    @ViewBuilder
    private func keyStatus(baseURL: String, key: String) -> some View {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let localWithoutKey = !trimmedBase.isEmpty && LLMConfig.isLocalHost(trimmedBase) && !hasKey
        HMEvidenceTag(
            tone: hasKey || localWithoutKey ? .confirmed : .neutral,
            text: hasKey ? "Key 已填写，将存入 Keychain" : (localWithoutKey ? "本地接口可不填 Key" : "Key 尚未填写"),
            systemImage: hasKey ? "key.fill" : "key"
        )
    }

    // MARK: - Profile section ("我的配置" — one-tap switch between saved setups)

    private var profileSection: some View {
        Section {
            if profiles.isEmpty {
                Text("尚未保存任何配置。先在下方选/填好接口与模型，再点「保存当前为配置…」即可。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    Button {
                        applyProfile(profile)
                    } label: {
                        profileRow(profile)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeProfile(profile)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newProfileName = activeProfileName ?? ""
                showingSaveProfile = true
            } label: {
                Label("保存当前为配置…", systemImage: "square.and.arrow.down")
            }
            .disabled(baseURL.isEmpty || textModel.isEmpty)
        } header: {
            Text("我的配置")
        } footer: {
            Text("把当前文本/图像接口 + 模型保存成一份配置，下次一键切回。API Key 仍按接口地址自动记忆，不会重复填写。")
        }
    }

    private func profileRow(_ profile: LLMConfig.Profile) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body.weight(.medium))
                    if activeProfileName == profile.name {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.footnote)
                    }
                }
                if !profile.textModel.isEmpty || !profile.visionModel.isEmpty {
                    HStack(spacing: 6) {
                        if !profile.textModel.isEmpty { Text(profile.textModel) }
                        if !profile.visionModel.isEmpty {
                            Text("·")
                            Text(profile.visionModel)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Text(URL(string: profile.textBaseURL)?.host ?? profile.textBaseURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "arrow.forward")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var saveProfileSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HMEditorGuide(
                        title: "保存双通道字段，不保存 Key",
                        message: "Profile 只记录文本 / 图像接口与模型，方便下次切换；Key 仍按接口地址留在系统 Keychain。",
                        systemImage: "bookmark",
                        tone: .confirmed
                    )
                }
                Section("配置名") {
                    TextField("如：智谱 GLM 免费", text: $newProfileName)
                }
                Section {
                    LabeledContent("文本接口") {
                        Text(URL(string: baseURL)?.host ?? baseURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !textModel.isEmpty {
                        LabeledContent("文本模型") {
                            Text(textModel).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    if !visionBaseURL.isEmpty, visionBaseURL != baseURL {
                        LabeledContent("图像接口") {
                            Text(URL(string: visionBaseURL)?.host ?? visionBaseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !visionModel.isEmpty {
                        LabeledContent("图像模型") {
                            Text(visionModel).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("将保存的配置")
                } footer: {
                    Text("API Key 不进入配置，仍保留在 Keychain 中（按接口地址记忆）。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(HMColors.background)
            .navigationTitle("保存当前配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingSaveProfile = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // Persist the current form fields first so the profile snapshot matches.
                        persist()
                        LLMConfig.saveCurrentAsProfile(name: newProfileName)
                        profiles = LLMConfig.profiles
                        activeProfileName = LLMConfig.activeProfileName
                        showingSaveProfile = false
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func applyProfile(_ profile: LLMConfig.Profile) {
        LLMConfig.applyProfile(profile)
        // Reflect into the local form fields and re-pull the matching API keys.
        baseURL = profile.textBaseURL
        textModel = profile.textModel
        visionBaseURL = profile.visionBaseURL
        visionModel = profile.visionModel
        textKey = LLMConfig.apiKey(forBaseURL: profile.textBaseURL) ?? ""
        let effectiveVisionBase = profile.visionBaseURL.isEmpty ? profile.textBaseURL : profile.visionBaseURL
        visionKey = LLMConfig.apiKey(forBaseURL: effectiveVisionBase) ?? ""
        activeProfileName = profile.name
    }

    private func removeProfile(_ profile: LLMConfig.Profile) {
        LLMConfig.removeProfile(named: profile.name)
        profiles = LLMConfig.profiles
        activeProfileName = LLMConfig.activeProfileName
    }

    // MARK: - Preset section

    private var presetSection: some View {
        Section {
            ForEach(presets) { preset in
                Menu {
                    Button("文本 + 图像都用此接口") { apply(preset, toText: true, toVision: true) }
                    Button("仅用作文本接口") { apply(preset, toText: true, toVision: false) }
                    Button("仅用作图像接口") { apply(preset, toText: false, toVision: true) }
                    if LLMConfig.isCustomPreset(id: preset.id) {
                        Divider()
                        Button("删除此接口", role: .destructive) { removePreset(preset) }
                    }
                } label: {
                    presetRow(preset)
                }
                .tint(.primary)
            }
            .onDelete(perform: deletePresets)

            Button {
                showingAddProvider = true
            } label: {
                Label("手动添加接口", systemImage: "plus.circle")
            }
        } header: {
            Text("快速选择")
        } footer: {
            Text("点接口可选择应用到「文本」「图像」或两者；自定义接口可左滑删除。")
        }
    }

    private func presetRow(_ preset: LLMConfig.Preset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(preset.name)
                if LLMConfig.isCustomPreset(id: preset.id) {
                    Text("自定义")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: 8) {
                if !preset.suggestedTextModel.isEmpty {
                    Text(preset.suggestedTextModel)
                }
                if !preset.suggestedVisionModel.isEmpty {
                    Text("·")
                    Text(preset.suggestedVisionModel)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }

    private func apply(_ preset: LLMConfig.Preset, toText: Bool, toVision: Bool) {
        if toText {
            baseURL = preset.baseURL
            if !preset.suggestedTextModel.isEmpty { textModel = preset.suggestedTextModel }
            textKey = LLMConfig.apiKey(forBaseURL: preset.baseURL) ?? ""
        }
        if toVision {
            visionBaseURL = preset.baseURL
            if !preset.suggestedVisionModel.isEmpty { visionModel = preset.suggestedVisionModel }
            visionKey = LLMConfig.apiKey(forBaseURL: preset.baseURL) ?? ""
        }
    }

    private func deletePresets(at offsets: IndexSet) {
        for index in offsets {
            let preset = presets[index]
            if LLMConfig.isCustomPreset(id: preset.id) {
                LLMConfig.removeCustomPreset(id: preset.id)
            }
        }
        presets = LLMConfig.presets
    }

    private func removePreset(_ preset: LLMConfig.Preset) {
        LLMConfig.removeCustomPreset(id: preset.id)
        presets = LLMConfig.presets
    }

    // MARK: - Persist

    private func persist() {
        let textBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let visionBaseRaw = visionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveVisionBase = visionBaseRaw.isEmpty ? textBase : visionBaseRaw

        LLMConfig.enabled = enabled
        LLMConfig.baseURL = textBase
        LLMConfig.visionBaseURL = (effectiveVisionBase == textBase) ? "" : effectiveVisionBase
        LLMConfig.textModel = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.visionModel = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)

        LLMConfig.setApiKey(textKey.trimmingCharacters(in: .whitespacesAndNewlines), forBaseURL: textBase)
        if effectiveVisionBase != textBase {
            LLMConfig.setApiKey(visionKey.trimmingCharacters(in: .whitespacesAndNewlines), forBaseURL: effectiveVisionBase)
        }
    }

    private func testConnection() async {
        await MainActor.run {
            testing = true
            testResult = nil
            testFailed = false
        }
        // Don't persist before testing — use whatever's in the form fields now.
        let client = LLMClient(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: textModel.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: textKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            let reply = try await client.complete(
                systemPrompt: "你是一个测试响应器，请用一句话回复 ✅。",
                user: "ping",
                temperature: 0.0
            )
            await MainActor.run {
                testing = false
                testResult = "连接 OK：\(reply.prefix(40))"
                testFailed = false
            }
        } catch {
            await MainActor.run {
                testing = false
                testResult = error.localizedDescription
                testFailed = true
            }
        }
    }

    private func testVisionConnection() async {
        await MainActor.run {
            testingVision = true
            visionTestResult = nil
            visionTestFailed = false
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let testImage = renderer.image { context in
            context.cgContext.setFillColor(UIColor.systemGray6.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.cgContext.setFillColor(UIColor.systemGray3.cgColor)
            context.cgContext.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let client = LLMClient(
            baseURL: effectiveVisionBaseURL,
            model: visionModel.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: visionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            let reply = try await client.analyzeImage(
                testImage,
                prompt: "这是连接测试图，不包含健康信息。请只回复 OK。",
                systemPrompt: nil,
                maxSide: 32,
                jpegQuality: 0.7,
                temperature: 0.0
            )
            await MainActor.run {
                testingVision = false
                visionTestResult = "连接 OK：\(reply.prefix(40))"
                visionTestFailed = false
            }
        } catch {
            await MainActor.run {
                testingVision = false
                visionTestResult = error.localizedDescription
                visionTestFailed = true
            }
        }
    }
}

/// Sheet for adding a custom provider to the preset list.
private struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (LLMConfig.Preset) -> Void

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var textModel: String = ""
    @State private var visionModel: String = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HMEditorGuide(
                        title: "只添加接口模板",
                        message: "这里仅保存名称、Base URL 和建议模型。添加后不会自动启用 AI、填写 Key 或发送任何数据。",
                        systemImage: "plus.circle",
                        tone: .estimate
                    )
                }
                Section("接口名称") {
                    TextField("如：我的自建服务", text: $name)
                }
                Section("Base URL") {
                    TextField("https://…/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                }
                Section {
                    TextField("建议文本模型（可留空）", text: $textModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                    TextField("建议视觉模型（可留空）", text: $visionModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                } header: {
                    Text("建议模型")
                } footer: {
                    Text("仅作为快速选择时的填充建议，保存后仍可在接口字段中修改。")
                }
                Section {
                    HMEditorCallout(
                        title: "此处不保存 API Key",
                        message: "把接口应用到文本或照片通道后再填写 Key；Key 将进入系统 Keychain，而不是接口模板。",
                        tone: .confirmed,
                        systemImage: "lock.fill"
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(HMColors.background)
            .navigationTitle("添加接口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let preset = LLMConfig.Preset(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            suggestedTextModel: textModel.trimmingCharacters(in: .whitespacesAndNewlines),
                            suggestedVisionModel: visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onAdd(preset)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
