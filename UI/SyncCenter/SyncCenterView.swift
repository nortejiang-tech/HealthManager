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
                        Label("立即同步（占位）", systemImage: "arrow.down.circle")
                    }
                    .disabled(true)
                    Text("Round 4 实现：包含回前台二次拉取。")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .task { await refreshReports() }
            .refreshable { await refreshReports() }
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

    @MainActor
    private func refreshReports() async {
        do {
            recentReports = try environment.database.read { db in
                try BackfillReport
                    .order(Column("started_at").desc)
                    .limit(20)
                    .fetchAll(db)
            }
        } catch {
            AppLogger.shared.error("Reports refresh failed: \(error.localizedDescription)")
        }
    }
}
