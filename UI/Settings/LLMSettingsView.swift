import SwiftUI

/// Configure the LLM endpoint that powers the AI commentary on daily / weekly summaries.
///
/// Reads + writes `LLMConfig` directly. API key lives in Keychain; baseURL / model /
/// enabled in UserDefaults. Presets populate the URL + suggested model with one tap;
/// users can still edit any field freely.
///
/// Privacy footer makes it explicit what gets sent.
struct LLMSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var enabled: Bool = LLMConfig.enabled
    @State private var baseURL: String = LLMConfig.baseURL
    @State private var textModel: String = LLMConfig.textModel
    @State private var visionModel: String = LLMConfig.visionModel
    @State private var apiKey: String = LLMConfig.apiKey ?? ""
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

            Section("快速选择") {
                ForEach(LLMConfig.presets) { preset in
                    Button {
                        baseURL = preset.baseURL
                        // Replace text/vision only if empty OR currently a preset value.
                        if textModel.isEmpty || isPresetTextModel() {
                            textModel = preset.suggestedTextModel
                        }
                        if visionModel.isEmpty || isPresetVisionModel() {
                            visionModel = preset.suggestedVisionModel
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            HStack(spacing: 8) {
                                Text(preset.suggestedTextModel)
                                if !preset.suggestedVisionModel.isEmpty {
                                    Text("·")
                                    Text(preset.suggestedVisionModel)
                                }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("接口") {
                TextField("Base URL（如 https://open.bigmodel.cn/api/paas/v4）", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                TextField("文本模型（用于日报/周报）", text: $textModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                TextField("视觉模型（用于饮食拍照分析，可留空）", text: $visionModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
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
                .disabled(testing || baseURL.isEmpty || textModel.isEmpty || apiKey.isEmpty)

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
        .confirmationDialog(
            "清除全部 LLM 配置？",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                LLMConfig.reset()
                enabled = LLMConfig.enabled
                textModel = ""
                baseURL = ""
                apiKey = ""
                testResult = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func persist() {
        LLMConfig.enabled = enabled
        LLMConfig.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.textModel = textModel.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.visionModel = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPresetTextModel() -> Bool {
        LLMConfig.presets.contains(where: { $0.suggestedTextModel == textModel })
    }

    private func isPresetVisionModel() -> Bool {
        LLMConfig.presets.contains(where: { !$0.suggestedVisionModel.isEmpty && $0.suggestedVisionModel == visionModel })
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
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
