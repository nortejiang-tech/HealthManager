import SwiftUI
import GRDB

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var healthKit: HealthKitManager

    @State private var dbSizeBytes: Int64 = 0
    @State private var sampleCount: Int = 0
    @State private var alertCount: Int = 0
    @State private var showingResetConfirm: Bool = false

    var body: some View {
        List {
            Section("应用") {
                LabeledContent("版本", value: Bundle.main.shortVersion + " (\(Bundle.main.buildVersion))")
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                    .font(.footnote.monospaced())
            }

            Section("HealthKit") {
                LabeledContent("授权状态", value: gateLabel)
                Button {
                    Task { await healthKit.refreshAuthorizationGate() }
                } label: {
                    Label("重新检查授权", systemImage: "arrow.clockwise")
                }
            }

            Section("数据库") {
                LabeledContent("路径", value: environment.database.databasePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                LabeledContent("文件大小", value: formatBytes(dbSizeBytes))
                LabeledContent("有效样本数", value: "\(sampleCount)")
                LabeledContent("未确认告警", value: "\(alertCount)")
            }

            Section("对账阈值（只读 V1）") {
                LabeledContent("核心指标", value: "体重 / 步数 / 心率 / 睡眠")
                LabeledContent("完整度警戒", value: "75%")
                LabeledContent("升级 critical", value: "连续 3 天缺失")
                LabeledContent("默认对账窗口", value: "过去 7 天")
                Text("V1 阈值固化；后续版本会暴露为可编辑设置项。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("隐私") {
                Text("所有数据存储在本地 SQLite 中。本 App 不上传任何健康数据到云端，不接入第三方分析服务。")
                    .font(.footnote)
                Text("HealthKit 数据本身由 Apple 在系统级加密保护；本 App 仅读取必要类型并按系统授权范围使用。")
                    .font(.footnote)
            }

            Section("Danger zone") {
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label("重新触发 onboarding 授权页", systemImage: "arrow.uturn.left.circle")
                }
            }
        }
        .navigationTitle("设置")
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog(
            "重新触发 onboarding 授权页？",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("继续", role: .destructive) {
                UserDefaults.standard.removeObject(forKey: "hk.hasRequestedAuthorization")
                Task { await healthKit.refreshAuthorizationGate() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会删除任何数据，仅重置「是否请求过授权」标记。仍需进入「设置 → 隐私 → 健康」修改实际授权。")
        }
    }

    private var gateLabel: String {
        switch healthKit.authorizationGate {
        case .unknown: return "未知"
        case .needsRequest: return "尚未请求"
        case .partiallyGranted: return "部分授权"
        case .granted: return "已授权"
        case .denied: return "被拒绝"
        }
    }

    private func refresh() async {
        do {
            let path = environment.database.databasePath
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = Int64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)

            let (samples, alerts) = try await environment.database.asyncRead { db -> (Int, Int) in
                let s = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
                let a = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0") ?? 0
                return (s, a)
            }
            await MainActor.run {
                dbSizeBytes = size
                sampleCount = samples
                alertCount = alerts
            }
        } catch {
            AppLogger.shared.error("Settings refresh failed: \(error.localizedDescription)")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private extension Bundle {
    var shortVersion: String { (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—" }
    var buildVersion: String { (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—" }
}
