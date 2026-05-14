import SwiftUI
import GRDB

/// Drill-in for the quality pill in the hero header. Hosts the old List sections
/// that the redesigned dashboard moved away from the front page.
struct DataQualityDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine

    @State private var todayQuality: DataQualityDaily?
    @State private var rawSampleCount: Int = 0
    @State private var lastIngest: Date?
    @State private var loadError: String?

    var body: some View {
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

            Section {
                NavigationLink {
                    SummaryView()
                } label: {
                    Label("日报 / 周报", systemImage: "doc.text")
                }
            } header: {
                Text("分析")
            }

            if let err = loadError {
                Section { Text(err).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("数据质量")
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do {
            let today = Self.dateKey.string(from: Date())
            let result = try await environment.database.asyncRead { db -> (Int, Date?, DataQualityDaily?) in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
                let maxIngested = try Int64.fetchOne(db, sql: "SELECT MAX(ingested_at) FROM health_samples_raw")
                let date = maxIngested.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let quality = try DataQualityDaily.fetchOne(db, key: today)
                return (total, date, quality)
            }
            await MainActor.run {
                rawSampleCount = result.0
                lastIngest = result.1
                todayQuality = result.2
                loadError = nil
            }
        } catch {
            await MainActor.run {
                loadError = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let dateKey: DateFormatter = {
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
