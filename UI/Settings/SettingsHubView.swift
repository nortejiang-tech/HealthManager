import SwiftUI

struct SettingsView: View {
    @Environment(\.hmDisplayMode) private var displayMode
    var body: some View {
        if displayMode == .classic {
            AdvancedSettingsView()
        } else {
            SettingsHubView()
        }
    }
}

private struct SettingsHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var healthKit: HealthKitManager

    var body: some View {
        List {
            Section("外观") {
                NavigationLink { AppearanceSettingsView() } label: {
                    Label("显示模式", systemImage: "rectangle.grid.2x2.fill")
                }
                .accessibilityIdentifier("settings-appearance")
            }
            Section("设备与数据") {
                NavigationLink { GarminConnectionView(manager: environment.garmin) } label: {
                    Label("佳明 Personal API", systemImage: "watchface.applewatch.case")
                }
                .accessibilityIdentifier("settings-garmin")
                NavigationLink {
                    AppleHealthPermissionEvidenceView(database: environment.database, healthKit: healthKit)
                } label: {
                    Label("Apple 健康权限", systemImage: "heart.fill")
                }
                NavigationLink { HealthBridgeSettingsView(bridge: environment.healthBridge) } label: {
                    Label("Mac 同步", systemImage: "laptopcomputer")
                }.accessibilityIdentifier("settings-bridge")
            }
            Section("分析与资料") {
                NavigationLink { LLMSettingsView() } label: {
                    Label("AI 摘要与照片分析", systemImage: "sparkles")
                }
                NavigationLink { FoodLibrarySettingsView() } label: {
                    Label("食材资料库", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("settings-food-library")
            }
            BackupSection()
            Section {
                NavigationLink { AdvancedSettingsView() } label: {
                    Label("更多设置与诊断", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings-advanced")
            }
            Section {
                DisclosureGroup("隐私与数据去向") {
                    Text("数据默认保存在本机。启用 Mac 同步后，健康数据经 iCloud 传到你的 Mac。AI 分析按配置发送摘要或主动选择的餐食图片。API Key 仅保存在本机钥匙串，不进入数据备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("版本", value: version)
            }
        }
        .navigationTitle("设置")
        .accessibilityIdentifier("settings-screen")
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}
