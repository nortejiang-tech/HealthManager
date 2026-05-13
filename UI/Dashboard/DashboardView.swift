import SwiftUI
import GRDB

struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var rawSampleCount: Int = 0
    @State private var lastIngest: Date?

    var body: some View {
        NavigationStack {
            List {
                Section("数据采集") {
                    LabeledContent("原始样本累计", value: "\(rawSampleCount)")
                    LabeledContent("最近写入时间", value: lastIngest.map { Self.formatter.string(from: $0) } ?? "—")
                }

                Section("最近同步") {
                    if let result = sync.lastResult {
                        LabeledContent("作业类型", value: result.jobType.rawValue)
                        LabeledContent("结果", value: result.succeeded ? "成功" : "失败")
                        LabeledContent("样本数", value: "\(result.totalSamples)")
                        LabeledContent("耗时", value: String(format: "%.1fs", result.endedAt.timeIntervalSince(result.startedAt)))
                        if let err = result.errorMessage {
                            Text(err).foregroundStyle(.red)
                        }
                    } else {
                        Text("尚无同步记录").foregroundStyle(.secondary)
                    }
                }

                Section("说明") {
                    Text("本页为 V1 占位。后续将展示体重/活动/睡眠/用药趋势卡片。")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            .navigationTitle("仪表盘")
            .refreshable {
                await refresh()
            }
            .task { await refresh() }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    @MainActor
    private func refresh() async {
        do {
            let (count, ingest) = try environment.database.read { db -> (Int, Date?) in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw") ?? 0
                let maxIngested = try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at) FROM health_samples_raw")
                let date = maxIngested.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                return (total, date)
            }
            rawSampleCount = count
            lastIngest = ingest
        } catch {
            AppLogger.shared.error("Dashboard refresh failed: \(error.localizedDescription)")
        }
    }
}
