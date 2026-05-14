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
    @State private var model: String = LLMConfig.model
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
                        if model.isEmpty || isCurrentPresetModel() {
                            model = preset.suggestedModel
                        }
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text(preset.suggestedModel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("接口") {
                TextField("Base URL（如 https://api.deepseek.com/v1）", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                TextField("模型名（如 deepseek-chat）", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.callout.monospaced())
                SecureField("API Key（sk-…）", text: $apiKey)
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
                        Text(testing ? "测试中…" : "测试连接")
                    }
                }
                .disabled(testing || baseURL.isEmpty || model.isEmpty || apiKey.isEmpty)

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
                baseURL = ""
                model = ""
                apiKey = ""
                testResult = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func persist() {
        LLMConfig.enabled = enabled
        LLMConfig.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        LLMConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCurrentPresetModel() -> Bool {
        LLMConfig.presets.contains(where: { $0.suggestedModel == model })
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
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
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
