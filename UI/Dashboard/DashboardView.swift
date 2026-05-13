import SwiftUI
import GRDB

struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var rawSampleCount: Int = 0
    @State private var lastIngest: Date?
    @State private var todayQuality: DataQualityDaily?
    @State private var unackAlertCount: Int = 0
    @State private var criticalAlertCount: Int = 0

    var body: some View {
        NavigationStack {
            List {
                Section("今日数据质量") {
                    if let q = todayQuality {
                        QualityScoreRow(label: "完整度", value: q.completenessScore)
                        QualityScoreRow(label: "新鲜度", value: q.freshnessScore)
                        QualityScoreRow(label: "冲突度（越高越好）", value: q.conflictScore)
                        if let missingJson = q.missingMetricsJson,
                           let missing = Self.decodeStringArray(missingJson),
                           !missing.isEmpty {
                            Text("缺失：\(missing.map(DailyReconciler.humanLabel(for:)).joined(separator: "、"))")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("尚未生成对账数据。先跑一次同步与对账。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("数据采集") {
                    LabeledContent("原始样本累计", value: "\(rawSampleCount)")
                    LabeledContent("最近写入时间", value: lastIngest.map { Self.formatter.string(from: $0) } ?? "—")
                }

                Section("告警") {
                    NavigationLink {
                        AlertsView()
                    } label: {
                        HStack {
                            Image(systemName: criticalAlertCount > 0
                                  ? "exclamationmark.triangle.fill"
                                  : (unackAlertCount > 0 ? "exclamationmark.circle" : "checkmark.circle"))
                                .foregroundStyle(criticalAlertCount > 0 ? .red : (unackAlertCount > 0 ? .orange : .green))
                            Text("待处理告警")
                            Spacer()
                            if unackAlertCount > 0 {
                                Text("\(unackAlertCount)")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(criticalAlertCount > 0 ? Color.red : Color.orange, in: Capsule())
                            } else {
                                Text("无").foregroundStyle(.secondary).font(.footnote)
                            }
                        }
                    }
                }

                Section("分析") {
                    NavigationLink {
                        SummaryView()
                    } label: {
                        Label("日报 / 周报", systemImage: "doc.text")
                    }
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
            }
            .navigationTitle("仪表盘")
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func decodeStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String]
    }

    @MainActor
    private func refresh() async {
        do {
            let today = Self.dateKeyFormatter.string(from: Date())
            let (count, ingest, q, unack, critical) = try environment.database.read { db -> (Int, Date?, DataQualityDaily?, Int, Int) in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
                let maxIngested = try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at) FROM health_samples_raw")
                let date = maxIngested.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let quality = try DataQualityDaily.fetchOne(db, key: today)
                let unackCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0") ?? 0
                let critCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0 AND severity = 'critical'") ?? 0
                return (total, date, quality, unackCount, critCount)
            }
            rawSampleCount = count
            lastIngest = ingest
            todayQuality = q
            unackAlertCount = unack
            criticalAlertCount = critical
        } catch {
            AppLogger.shared.error("Dashboard refresh failed: \(error.localizedDescription)")
        }
    }
}

private struct QualityScoreRow: View {
    let label: String
    let value: Double?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if let v = value {
                Text(String(format: "%.0f%%", v * 100))
                    .foregroundStyle(color(for: v))
                    .font(.body.monospacedDigit())
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func color(for v: Double) -> Color {
        if v >= 0.8 { return .green }
        if v >= 0.5 { return .orange }
        return .red
    }
}
