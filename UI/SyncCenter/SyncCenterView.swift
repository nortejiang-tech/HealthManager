import SwiftUI
import GRDB

struct SyncCenterView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var backfillDays: Int = 30
    @State private var recentReports: [BackfillReport] = []

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("当前阶段", value: phaseLabel)
                    if sync.isBusy {
                        ProgressView(sync.progressDescription.isEmpty ? "处理中…" : sync.progressDescription)
                    } else if !sync.progressDescription.isEmpty {
                        Text(sync.progressDescription).foregroundStyle(.secondary).font(.footnote)
                    }
                }

                Section("历史回补") {
                    Stepper(value: $backfillDays, in: 7...90, step: 1) {
                        Text("回溯天数：\(backfillDays)")
                    }
                    Button {
                        Task { await sync.runBackfill(days: backfillDays, trigger: .user); await refreshReports() }
                    } label: {
                        Label("开始回补", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(sync.isBusy)
                }

                Section("手动一键同步") {
                    Button {
                        Task { await sync.runManualSync() }
                    } label: {
                        Label("立即同步", systemImage: "arrow.down.circle")
                    }
                    .disabled(sync.isBusy)
                    Text("会先拉一次，再提示你打开 Garmin / 米家等外部 App，回到本 App 后自动续跑；并把已记录的饮食营养写回 Apple 健康（首次会请求授权）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("数据对账") {
                    Button {
                        Task { await sync.runReconcile(windowDays: 7, trigger: .user) }
                    } label: {
                        Label(sync.isReconciling ? "对账中…" : "立即对账（7 天）", systemImage: "checkmark.seal")
                    }
                    .disabled(sync.isReconciling)
                    if let outcome = sync.lastReconcileOutcome {
                        Text("上次：\(outcome.datesProcessed.count) 天，告警 \(outcome.alertsEmitted) 条")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let errors = sync.lastResult?.perTypeErrors, !errors.isEmpty {
                    Section {
                        DisclosureGroup("失败明细（\(errors.count)）") {
                            ForEach(errors, id: \.hkType) { err in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: err.isAuthDenied
                                              ? "lock.fill"
                                              : "exclamationmark.triangle.fill")
                                            .foregroundStyle(err.isAuthDenied ? .orange : .red)
                                        Text(DailyReconciler.humanLabel(for: err.hkType)).bold()
                                    }
                                    Text("阶段：\(err.stage.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(err.underlying)
                                        .font(.caption)
                                        .foregroundStyle(err.isAuthDenied ? .orange : .red)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                Section("最近回补报告") {
                    if recentReports.isEmpty {
                        Text("尚无报告。先执行一次回补。").foregroundStyle(.secondary)
                    } else {
                        ForEach(recentReports) { report in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.hkType).font(.system(.body, design: .monospaced))
                                HStack {
                                    Text("样本：\(report.sampleCount)")
                                    if report.missing { Text("缺失").foregroundStyle(.orange) }
                                    Text(report.status.rawValue).foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle("同步中心")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task { await refreshReports() }
            .refreshable { await refreshReports() }
            .alert(
                sync.manualSyncPrompt?.title ?? "",
                isPresented: Binding(
                    get: { sync.manualSyncPrompt != nil },
                    set: { presented in if !presented { sync.acknowledgeExternalSyncDone() } }
                ),
                presenting: sync.manualSyncPrompt
            ) { _ in
                Button("已完成") { sync.acknowledgeExternalSyncDone() }
            } message: { prompt in
                Text(prompt.message)
            }
        }
    }

    private var phaseLabel: String {
        switch sync.phase {
        case .idle: return "空闲"
        case .requestingAuth: return "请求授权"
        case .backfilling: return "回补中"
        case .syncingIncremental: return "增量同步"
        case .waitingExternalSync: return "等待外部 App 同步"
        case .syncingIncremental2: return "二次增量"
        case .reconciling: return "对账中"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }

    private func refreshReports() async {
        do {
            let reports = try await environment.database.asyncRead { db -> [BackfillReport] in
                try BackfillReport
                    .order(Column("started_at").desc)
                    .limit(20)
                    .fetchAll(db)
            }
            await MainActor.run { recentReports = reports }
        } catch {
            AppLogger.shared.error("Reports refresh failed: \(error.localizedDescription)")
        }
    }
}
