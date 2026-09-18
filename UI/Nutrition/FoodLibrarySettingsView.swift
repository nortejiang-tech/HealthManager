import SwiftUI

/// 「更多 → 设置 → 食材资料库」：USDA FoodData Central 个人 API Key 的一次配置。
/// key 存 Keychain，不进备份包/日志/仓库；与 LLM key 相互独立。
struct FoodLibrarySettingsView: View {
    @State private var keyInput: String = ""
    @State private var isConfigured: Bool = USDAKeyStore.isConfigured
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(
                    "USDA FoodData Central",
                    value: isConfigured ? "已配置" : "未配置"
                )
                if isConfigured {
                    Button(role: .destructive) {
                        USDAKeyStore.setApiKey("")
                        isConfigured = false
                        saveMessage = "已清除 Key；本地搜索与已添加食材仍可用。"
                    } label: {
                        Text("清除 Key")
                    }
                }
            } header: {
                Text("状态")
            } footer: {
                Text("未配置时：本地目录与已导入资料照常可用，只是无法联网检索新食材。")
            }

            if !isConfigured {
                Section {
                    SecureField("data.gov API Key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("usda-key-input")
                    Button {
                        USDAKeyStore.setApiKey(keyInput)
                        keyInput = ""
                        isConfigured = USDAKeyStore.isConfigured
                        saveMessage = isConfigured ? "已保存。之后在「营养表 → ＋」即可联网检索添加食材。" : "保存失败，请重试。"
                    } label: {
                        Text("保存 Key")
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("usda-key-save")
                } header: {
                    Text("配置")
                } footer: {
                    Text("在 data.gov 免费申请个人 API Key（每个 key 每小时 1000 次限额，个人使用足够）。Key 只存本机 Keychain，不进入备份包、日志或代码仓库；与「AI 摘要」的 key 相互独立。")
                }
            }

            if let saveMessage {
                Section {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Link("USDA API 官方说明", destination: URL(string: "https://fdc.nal.usda.gov/api-guide/")!)
                Link("数据类型说明（Foundation / SR Legacy / FNDDS）", destination: URL(string: "https://fdc.nal.usda.gov/data-documentation/")!)
            } header: {
                Text("来源与授权")
            } footer: {
                Text("USDA 数据为公有领域（CC0）。Foundation 为分析数据，SR Legacy 为历史汇编，FNDDS 为膳食调查汇编；品牌标签数据不在本轮检索范围。")
            }
        }
        .navigationTitle("食材资料库")
        .navigationBarTitleDisplayMode(.inline)
    }
}
