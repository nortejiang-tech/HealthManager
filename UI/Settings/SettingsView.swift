import SwiftUI
import GRDB

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var healthKit: HealthKitManager
    @Environment(\.openURL) private var openURL

    @State private var dbSizeBytes: Int64 = 0
    @State private var sampleCount: Int = 0
    @State private var alertCount: Int = 0
    @State private var showingResetConfirm: Bool = false
    @State private var showingResetThresholdsConfirm: Bool = false

    // Editable threshold state — mirrors `ReconcilerSettings` and persists on change.
    @State private var completenessPct: Double = ReconcilerSettings.completenessThreshold * 100
    @State private var conflictMinSources: Int = ReconcilerSettings.conflictMinSources
    @State private var consecutiveCritical: Int = ReconcilerSettings.consecutiveMissingForCritical
    @State private var defaultWindowDays: Int = ReconcilerSettings.defaultWindowDays

    @State private var exportURL: URL?

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
                Button {
                    if let url = URL(string: "x-apple-health://") {
                        openURL(url)
                    }
                } label: {
                    Label("打开 Apple 健康 App", systemImage: "heart.text.square")
                }
            }

            Section("数据库") {
                LabeledContent("路径", value: environment.database.databasePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                LabeledContent("文件大小", value: formatBytes(dbSizeBytes))
                LabeledContent("有效样本数", value: "\(sampleCount)")
                LabeledContent("未确认告警", value: "\(alertCount)")

                Button {
                    Task { await exportDatabase() }
                } label: {
                    Label("导出本地数据库快照…", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Stepper(value: $completenessPct, in: 30...100, step: 5) {
                    HStack {
                        Text("完整度警戒线")
                        Spacer()
                        Text("\(Int(completenessPct))%").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: completenessPct) { _, new in
                    ReconcilerSettings.completenessThreshold = new / 100.0
                }

                Stepper(value: $conflictMinSources, in: 2...6) {
                    HStack {
                        Text("冲突阈值（同小时来源数）")
                        Spacer()
                        Text("≥ \(conflictMinSources)").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: conflictMinSources) { _, new in
                    ReconcilerSettings.conflictMinSources = new
                }

                Stepper(value: $consecutiveCritical, in: 1...14) {
                    HStack {
                        Text("升级 critical 的连续缺失天数")
                        Spacer()
                        Text("\(consecutiveCritical) 天").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: consecutiveCritical) { _, new in
                    ReconcilerSettings.consecutiveMissingForCritical = new
                }

                Stepper(value: $defaultWindowDays, in: 1...30) {
                    HStack {
                        Text("默认对账窗口")
                        Spacer()
                        Text("\(defaultWindowDays) 天").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: defaultWindowDays) { _, new in
                    ReconcilerSettings.defaultWindowDays = new
                }

                Button(role: .destructive) {
                    showingResetThresholdsConfirm = true
                } label: {
                    Label("恢复默认阈值", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("对账阈值")
            } footer: {
                Text("修改后立即生效，下次「立即对账」按新阈值执行。核心指标固定为 体重/步数/心率/睡眠。")
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
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
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
        .confirmationDialog(
            "恢复对账阈值为默认值？",
            isPresented: $showingResetThresholdsConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                ReconcilerSettings.resetToDefaults()
                completenessPct = ReconcilerSettings.completenessThreshold * 100
                conflictMinSources = ReconcilerSettings.conflictMinSources
                consecutiveCritical = ReconcilerSettings.consecutiveMissingForCritical
                defaultWindowDays = ReconcilerSettings.defaultWindowDays
            }
            Button("取消", role: .cancel) {}
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

    /// Copy the live SQLite file (plus -wal / -shm if present) into a tmp file the user
    /// can share via the system share sheet. The original DB pool stays open; we copy
    /// rather than vacuum-into so the operation is read-only and fast.
    private func exportDatabase() async {
        do {
            let srcPath = environment.database.databasePath
            let tmpDir = FileManager.default.temporaryDirectory
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let dstURL = tmpDir.appendingPathComponent("HealthManager-\(stamp).sqlite")
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(atPath: srcPath, toPath: dstURL.path)
            await MainActor.run { exportURL = dstURL }
        } catch {
            AppLogger.shared.error("DB export failed: \(error.localizedDescription)")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private extension Bundle {
    var shortVersion: String { (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—" }
    var buildVersion: String { (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—" }
}
