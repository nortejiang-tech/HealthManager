import SwiftUI

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
    @State private var showingAddProvider: Bool = false
    @State private var showingResetConfirm: Bool = false

    @State private var testing: Bool = false
    @State private var testResult: String?
    @State private var testFailed: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 摘要", isOn: $enabled)
            } header: {
                Text("总开关")
            } footer: {
                Text("开启后，「总结」页会在本地确定性摘要旁边显示 AI 评注。关闭则只用本地摘要。")
            }

            presetSection

            Section("文本接口") {
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
            }

            Section {
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
            } header: {
                Text("图像接口")
            } footer: {
                Text("图像接口可与文本接口使用不同的服务商；两者的 API Key 各自独立保存。")
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if testing {
                            ProgressView().controlSize(.small)
                        }
                        Text(testing ? "测试中…" : "测试文本模型连接")
                    }
                }
                .disabled(testing || baseURL.isEmpty || textModel.isEmpty || textKey.isEmpty)

                if let result = testResult {
                    Label(result, systemImage: testFailed ? "xmark.octagon" : "checkmark.seal")
                        .foregroundStyle(testFailed ? .red : .green)
                        .font(.footnote)
                }
            }

            Section {
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label("清除所有 LLM 配置", systemImage: "trash")
                }
            } footer: {
                Text("发送给 LLM 的内容仅限本机已经聚合过的「日报 / 周报」纯文本——不会上传原始样本、设备 ID 或来源信息。Key 存储在 iOS Keychain，不随 DB 导出。")
            }
        }
        .navigationTitle("AI 摘要")
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
        }
        .onChange(of: visionBaseURL) { _, newValue in
            if let remembered = LLMConfig.apiKey(forBaseURL: newValue) { visionKey = remembered }
        }
        .sheet(isPresented: $showingAddProvider) {
            AddProviderView { preset in
                LLMConfig.addCustomPreset(preset)
                presets = LLMConfig.presets
            }
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
            }
            Button("取消", role: .cancel) {}
        }
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
            }
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
