import SwiftUI
import GRDB
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var healthKit: HealthKitManager
    @EnvironmentObject private var backup: BackupManager
    @Environment(\.openURL) private var openURL

    @State private var dbSizeBytes: Int64?
    @State private var sampleCount: Int?
    @State private var alertCount: Int?
    @State private var tableCounts: [(table: String, count: Int)] = []
    @State private var showingResetConfirm: Bool = false
    @State private var showingResetThresholdsConfirm: Bool = false
    @State private var loadError: String?

    // Editable threshold state — mirrors `ReconcilerSettings` and persists on change.
    @State private var completenessPct: Double = ReconcilerSettings.completenessThreshold * 100
    @State private var conflictMinSources: Int = ReconcilerSettings.conflictMinSources
    @State private var consecutiveCritical: Int = ReconcilerSettings.consecutiveMissingForCritical
    @State private var defaultWindowDays: Int = ReconcilerSettings.defaultWindowDays

    @State private var exportSnapshot: ExportDatabaseSnapshot?
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                HMDecisionLens(
                    title: "默认留在本机，可选 AI 才外发",
                    text: "Apple 健康记录按系统授权读取后写入本机数据库。只有你启用并实际使用 AI 时，日报 / 周报会发送聚合摘要文本，餐食照片分析会发送本次主动选择的图片。",
                    tone: .confirmed,
                    systemImage: "lock.shield"
                )

                HMProvenanceRail(
                    title: "数据去向",
                    steps: [
                        .init(
                            title: "健康记录",
                            detail: "按系统授权读取",
                            tone: .confirmed,
                            systemImage: "heart.text.square",
                            accessibilityIdentifier: nil
                        ),
                        .init(
                            title: "本机数据库",
                            detail: sampleCount.map { "\($0) 条有效样本" } ?? "统计待读取",
                            tone: sampleCount == nil ? .neutral : .confirmed,
                            systemImage: "externaldrive",
                            accessibilityIdentifier: nil
                        ),
                        .init(
                            title: "外部 AI",
                            detail: aiDataRouteLabel,
                            tone: LLMConfig.enabled ? .estimate : .neutral,
                            systemImage: "sparkles",
                            accessibilityIdentifier: nil
                        )
                    ]
                )
            }

            Section("应用") {
                LabeledContent("版本", value: Bundle.main.shortVersion + " (\(Bundle.main.buildVersion))")
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                    .font(.footnote.monospaced())
            }

            Section("HealthKit") {
                NavigationLink {
                    AppleHealthPermissionEvidenceView(
                        database: environment.database,
                        healthKit: healthKit
                    )
                } label: {
                    HStack {
                        Label("Apple 健康权限", systemImage: "heart.text.square")
                        Spacer()
                        Text(gateLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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
                LabeledContent("文件大小", value: dbSizeBytes.map(formatBytes) ?? "—")
                LabeledContent("有效样本数", value: sampleCount.map { String($0) } ?? "—")
                LabeledContent("未确认告警", value: alertCount.map { String($0) } ?? "—")

                if !tableCounts.isEmpty {
                    DisclosureGroup("逐表行数（诊断）") {
                        ForEach(tableCounts, id: \.table) { entry in
                            LabeledContent(entry.table, value: String(entry.count))
                                .font(.caption.monospaced())
                        }
                    }
                }

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

            Section {
                NavigationLink {
                    LLMSettingsView()
                } label: {
                    HStack {
                        Label("AI 摘要与照片分析", systemImage: "sparkles")
                        Spacer()
                        Text(llmStatusLabel)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            } header: {
                Text("智能分析")
            } footer: {
                Text("文本评注和照片分析可以使用不同的 OpenAI 兼容接口；API Key 存在系统 Keychain，不进入数据库快照。")
            }

            Section("通知") {
                LabeledContent("用药提醒授权", value: notifStatusLabel)
                if notifStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("前往系统设置开启通知", systemImage: "bell.badge")
                    }
                } else if notifStatus == .notDetermined {
                    Button {
                        Task {
                            _ = await NotificationScheduler.shared.requestAuthorization()
                            await refreshNotifStatus()
                        }
                    } label: {
                        Label("请求通知权限", systemImage: "bell")
                    }
                }
            }

            BackupSection()

            Section("隐私") {
                Text("健康记录与应用记录默认存储在本地 SQLite 中。若你在「数据备份」中选择文件夹（含 iCloud Drive），App 会把解析后数据的明文备份包写入该文件夹；数据库导出不包含系统 Keychain 里的 API Key。")
                    .font(.footnote)
                Text("若启用并实际使用 AI，外部文本服务会收到本地聚合后的日报 / 周报文本，外部图像服务会收到你在餐食编辑器主动选择的图片；不会自动上传原始 HealthKit 样本或整个照片库。")
                    .font(.footnote)
            }

            if let loadError {
                Section {
                    HMInlineRecovery(
                        title: "设置统计读取失败",
                        message: "设置本身没有被修改；可重新读取数据库统计。",
                        technicalDetails: loadError,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
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
        .task {
            await refresh()
            await refreshNotifStatus()
        }
        .refreshable {
            await refresh()
            await refreshNotifStatus()
        }
        .sheet(item: $exportSnapshot) { snapshot in
            ShareSheet(items: [snapshot.url])
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
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
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

    private var llmStatusLabel: String {
        if !LLMConfig.enabled { return "已关闭" }
        if LLMConfig.isConfigured, LLMConfig.isVisionConfigured { return "双通道已配置" }
        if LLMConfig.isConfigured { return "文本已配置" }
        if LLMConfig.isVisionConfigured { return "照片已配置" }
        return "未配置"
    }

    private var aiDataRouteLabel: String {
        if !LLMConfig.enabled { return "已关闭，不发送" }
        if LLMConfig.isConfigured || LLMConfig.isVisionConfigured { return "仅在主动使用时发送" }
        return "未配置，不发送"
    }

    private var notifStatusLabel: String {
        switch notifStatus {
        case .notDetermined: return "尚未请求"
        case .denied: return "已拒绝"
        case .authorized: return "已授权"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时（App Clip）"
        @unknown default: return "未知"
        }
    }

    private func refreshNotifStatus() async {
        let status = await NotificationScheduler.shared.currentAuthorizationStatus()
        await MainActor.run { notifStatus = status }
    }

    private var gateLabel: String {
        switch healthKit.authorizationGate {
        case .unknown: return "未知"
        case .needsRequest: return "尚未请求"
        case .partiallyGranted: return "已请求 / 范围未知"
        case .granted: return "无需再次请求"
        case .denied: return healthKit.isAvailable ? "授权未建立" : "本机不可用"
        }
    }

    private func refresh() async {
        do {
            let path = environment.database.databasePath
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value

            let (samples, alerts, counts) = try await environment.database.asyncRead { db -> (Int, Int, [(String, Int)]) in
                let s = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
                let a = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0") ?? 0
                var tables: [(String, Int)] = []
                for spec in BackupExporter.tables {
                    let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(spec.table)") ?? 0
                    tables.append((spec.table, c))
                }
                return (s, a, tables)
            }
            await MainActor.run {
                dbSizeBytes = size
                sampleCount = samples
                alertCount = alerts
                tableCounts = counts
                loadError = nil
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
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
            await MainActor.run { exportSnapshot = ExportDatabaseSnapshot(url: dstURL) }
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

/// 数据备份区（独立子视图：选择位置 / 立即备份 / 恢复历史数据）。
/// 契约见 docs/adr/ADR-003 与 docs/export-schema.md。
private struct BackupSection: View {
    @EnvironmentObject private var backup: BackupManager

    @State private var showLocationPicker = false
    @State private var showRestorePicker = false
    @State private var locationError: String?

    var body: some View {
        Section {
            LabeledContent(
                "备份位置",
                value: backup.configuredLocationURL?.lastPathComponent ?? "未设置"
            )
            if let lastExport = backup.lastExportAt {
                LabeledContent(
                    "上次备份",
                    value: lastExport.formatted(date: .abbreviated, time: .shortened)
                )
            }

            Button {
                showLocationPicker = true
            } label: {
                Label(
                    backup.configuredLocationURL == nil ? "选择备份文件夹…" : "更改备份文件夹…",
                    systemImage: "folder.badge.gearshape"
                )
            }

            if backup.configuredLocationURL != nil {
                Button {
                    Task { await backup.exportNow() }
                } label: {
                    if backup.isExporting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("备份中…")
                        }
                    } else {
                        Label("立即备份", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(backup.isExporting)
            }

            Button {
                showRestorePicker = true
            } label: {
                if backup.isRestoring {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("恢复中…")
                    }
                } else {
                    Label("恢复历史数据…", systemImage: "arrow.down.doc")
                }
            }
            .disabled(backup.isRestoring)

            if let error = backup.lastExportError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(HMColors.actionRequired)
            }
            if let error = backup.lastRestoreError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(HMColors.actionRequired)
            }
            if let summary = backup.lastRestoreSummary {
                Text("恢复完成：新增 \(summary.totalImported) 行，已存在而跳过 \(summary.totalSkipped) 行。")
                    .font(.footnote)
                    .foregroundStyle(HMColors.confirmed)
            }
        } header: {
            Text("数据备份")
        } footer: {
            Text("备份包写入你选择的文件夹（可放在 iCloud Drive，由你的 Apple 账号保护），内容为明文 JSONL，App 自身不上传；退到后台时自动备份。重装后可在引导页或此处恢复；恢复只补缺、不覆盖，可重复执行。照片与 Apple 健康原始样本不包含在备份包内。")
        }
        .sheet(isPresented: $showLocationPicker) {
            FolderPicker { url in
                do {
                    try backup.setLocation(url)
                    locationError = nil
                    Task { await backup.exportNow() }
                } catch {
                    locationError = "无法保存备份位置：\(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showRestorePicker) {
            FolderPicker { url in
                Task { await backup.restore(from: url) }
            }
        }
        .alert(
            "备份位置",
            isPresented: .init(
                get: { locationError != nil },
                set: { if !$0 { locationError = nil } }
            )
        ) {
            Button("确定", role: .cancel) { locationError = nil }
        } message: {
            Text(locationError ?? "")
        }
    }
}

private struct ExportDatabaseSnapshot: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct AppleHealthPermissionEvidenceView: View {
    @ObservedObject var healthKit: HealthKitManager
    @Environment(\.openURL) private var openURL

    let database: DatabaseManager

    @State private var evidenceByType: [String: SampleEvidence] = [:]
    @State private var loadError: String?
    @State private var isRefreshing: Bool = false
    @State private var hasLoadedEvidence: Bool = false

    init(database: DatabaseManager, healthKit: HealthKitManager) {
        self.database = database
        self.healthKit = healthKit
    }

    var body: some View {
        List {
            Section {
                HMDecisionLens(
                    title: readGateTitle,
                    text: readGateDetail,
                    tone: readGateTone,
                    systemImage: "heart.text.square"
                )
            }

            Section {
                if hasLoadedEvidence {
                    ForEach(permissionGroups) { group in
                        evidenceRow(for: group)
                    }
                } else if loadError == nil {
                    ProgressView("正在读取最近导入证据…")
                }
            } header: {
                Text("最近导入证据")
            } footer: {
                Text("Apple 不向 App 提供完整的读取授权清单。这里显示的是本机数据库最近实际导入到的样本；没有样本不等于没有授权。")
            }

            Section("饮食营养写回") {
                HMInformationRow(
                    systemImage: "fork.knife",
                    tone: healthKit.isNutritionWriteAuthorized ? .confirmed : .actionRequired,
                    title: healthKit.isNutritionWriteAuthorized
                        ? "至少一个营养类型可写"
                        : "尚未观察到写回授权",
                    detail: healthKit.isNutritionWriteAuthorized
                        ? "这是系统可观察的写回状态；不代表所有读取类型均已授权。"
                        : "保存包含营养值的餐食时可按需请求。读取范围与写回授权相互独立。"
                )

                Button {
                    Task {
                        _ = await healthKit.requestNutritionWriteAuthorization()
                        await refresh()
                    }
                } label: {
                    Label("请求饮食营养写回权限", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(isRefreshing ? "正在重新检测…" : "重新检测", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)

                Button {
                    if let url = URL(string: "x-apple-health://") {
                        openURL(url)
                    }
                } label: {
                    Label("在 Apple 健康中修改权限", systemImage: "heart.text.square")
                }
            } footer: {
                Text("在健康 App 中修改后返回这里，再点“重新检测”。")
            }

            if let loadError {
                Section {
                    HMInlineRecovery(
                        title: "权限证据读取失败",
                        message: "系统授权没有被修改；失败只影响本页的本地样本证据。",
                        technicalDetails: loadError,
                        actionTitle: "重试"
                    ) {
                        Task { await refresh() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("Apple 健康权限")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private func evidenceRow(for group: PermissionGroup) -> some View {
        let evidence = group.identifiers.reduce(SampleEvidence.zero) { partial, identifier in
            partial.merging(evidenceByType[identifier] ?? .zero)
        }

        HMInformationRow(
            systemImage: group.systemImage,
            tone: evidence.sampleCount > 0 ? .confirmed : .neutral,
            title: group.title,
            detail: evidence.sampleCount > 0
                ? "最近实际导入 \(evidence.sampleCount) 条样本"
                : "本地暂无样本，读取授权仍无法据此判断",
            trailingText: evidence.lastIngestedAt.map(formatTime) ?? "暂无证据",
            trailingTone: evidence.sampleCount > 0 ? .confirmed : .neutral
        )
    }

    private var readGateTitle: String {
        guard healthKit.isAvailable else { return "本机 HealthKit 不可用" }
        switch healthKit.authorizationGate {
        case .unknown: return "授权状态待重新检查"
        case .needsRequest: return "尚未请求 Apple 健康授权"
        case .partiallyGranted: return "已请求授权，读取范围看实际证据"
        case .granted: return "系统认为当前无需再次请求"
        case .denied: return "Apple 健康连接尚未建立"
        }
    }

    private var readGateDetail: String {
        guard healthKit.isAvailable else {
            return "本地数据库不会因此清除；请在支持 HealthKit 的 iPhone 上检查。"
        }
        switch healthKit.authorizationGate {
        case .unknown:
            return "系统请求状态暂未确定。重新检测不会删除或改写任何健康记录。"
        case .needsRequest:
            return "进入授权流程后由系统展示类型范围；本页不会预先假定你会授予哪些读取类型。"
        case .partiallyGranted:
            return "Apple 不公开完整读取清单，因此下方只展示最近真实导入证据，不能把无样本写成未授权。"
        case .granted:
            return "“无需再次请求”只表示系统授权请求状态，不证明每个读取类型都有数据或已开放。"
        case .denied:
            return "当前连接未建立；既有本地数据仍保留，可在 Apple 健康中修改后重新检测。"
        }
    }

    private var readGateTone: HMSemanticTone {
        switch healthKit.authorizationGate {
        case .granted, .partiallyGranted: return .confirmed
        case .unknown: return .neutral
        case .needsRequest, .denied: return .actionRequired
        }
    }

    private var permissionGroups: [PermissionGroup] {
        [
            PermissionGroup(
                title: "活动与步数",
                systemImage: "figure.walk",
                identifiers: HealthKitTypeCatalog.activityQuantities.map(\.rawValue)
                    + [HealthKitTypeCatalog.workoutType.identifier]
            ),
            PermissionGroup(
                title: "睡眠",
                systemImage: "moon.zzz",
                identifiers: HealthKitTypeCatalog.categoryIdentifiers.map(\.rawValue)
            ),
            PermissionGroup(
                title: "体重与体成分",
                systemImage: "scalemass",
                identifiers: HealthKitTypeCatalog.bodyCompositionQuantities.map(\.rawValue)
            ),
            PermissionGroup(
                title: "心率与生命体征",
                systemImage: "waveform.path.ecg",
                identifiers: HealthKitTypeCatalog.cardioQuantities.map(\.rawValue)
            ),
            PermissionGroup(
                title: "饮食营养读取",
                systemImage: "fork.knife",
                identifiers: HealthKitTypeCatalog.nutritionQuantities.map(\.rawValue)
            )
        ]
    }

    private func refresh() async {
        await MainActor.run { isRefreshing = true }
        await healthKit.refreshAuthorizationGate()
        do {
            let evidence = try await AppleHealthPermissionEvidenceLoader(database: database).load()
            await MainActor.run {
                evidenceByType = evidence
                loadError = nil
                isRefreshing = false
                hasLoadedEvidence = true
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    private func formatTime(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}

private struct PermissionGroup: Identifiable {
    let title: String
    let systemImage: String
    let identifiers: [String]
    var id: String { title }
}

struct SampleEvidence: Sendable, Equatable {
    let sampleCount: Int
    let lastIngestedAt: Int64?

    static let zero = SampleEvidence(sampleCount: 0, lastIngestedAt: nil)

    func merging(_ other: SampleEvidence) -> SampleEvidence {
        SampleEvidence(
            sampleCount: sampleCount + other.sampleCount,
            lastIngestedAt: maxOptional(lastIngestedAt, other.lastIngestedAt)
        )
    }

    private func maxOptional(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }
}

struct AppleHealthPermissionEvidenceLoader: Sendable {
    let database: DatabaseManager

    func load() async throws -> [String: SampleEvidence] {
        try await database.asyncRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT hk_type,
                       COUNT(*) AS sample_count,
                       MAX(ingested_at) AS last_ingested_at
                FROM health_samples_raw
                WHERE is_deleted = 0
                GROUP BY hk_type
                """
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let type: String = row["hk_type"]
                let count: Int = row["sample_count"]
                let last: Int64? = row["last_ingested_at"]
                return (type, SampleEvidence(sampleCount: count, lastIngestedAt: last))
            })
        }
    }
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
