import SwiftUI
import GRDB

struct TrainingRawRecordsView: View {
    let metric: TrainingMetric
    @EnvironmentObject private var environment: AppEnvironment
    @State private var records: [HealthSampleRaw] = []
    @State private var count = 0
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        List {
            Section {
                Text("近8周，共\(count)条；展示最近\(records.count)条原始记录。夜间指标对应的原始类型也可能包含日间记录，详细计算仍以主睡眠区间筛选。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView("正在读取原始记录…") }
            else if let error { Text(error) }
            else if records.isEmpty { Text("近8周暂无相关原始记录") }
            ForEach(records, id: \.sampleUUID) { raw in
                DisclosureGroup {
                    LabeledContent("测量开始", value: TrainingText.time(Date(timeIntervalSince1970: Double(raw.startAt))))
                    LabeledContent("测量结束", value: TrainingText.time(Date(timeIntervalSince1970: Double(raw.endAt))))
                    LabeledContent("入库时间", value: TrainingText.time(Date(timeIntervalSince1970: Double(raw.ingestedAt))))
                    LabeledContent("设备", value: [raw.deviceName, raw.deviceModel].compactMap { $0 }.joined(separator: " · "))
                    Text("来源标识：\(raw.sourceBundleId ?? "未标注")").font(.caption).textSelection(.enabled)
                    Text("记录ID：\(raw.sampleUUID)").font(.caption).textSelection(.enabled)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rawValue(raw)).font(.headline)
                        Text("\(TrainingText.time(Date(timeIntervalSince1970: Double(raw.startAt)))) · \(raw.sourceName ?? "来源未标注")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("相关原始记录")
        .task {
            defer { loading = false }
            guard let type = metric.sampleType else { return }
            let now = Date(), begin = Calendar.current.date(byAdding: .day, value: -55, to: Calendar.current.startOfDay(for: now))!
            do {
                let result = try await environment.database.asyncRead { db -> ([HealthSampleRaw], Int) in
                    let filter = "hk_type = ? AND is_deleted = 0 AND start_at >= ? AND end_at <= ? AND ingested_at <= ?"
                    let args: StatementArguments = [type, begin.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970]
                    let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_samples_raw WHERE \(filter)", arguments: args) ?? 0
                    let values = try HealthSampleRaw.fetchAll(db, sql: "SELECT * FROM health_samples_raw WHERE \(filter) ORDER BY start_at DESC, sample_uuid LIMIT 200", arguments: args)
                    return (values, total)
                }
                guard !Task.isCancelled else { return }
                records = result.0; count = result.1
            } catch { self.error = error.localizedDescription }
        }
    }
    private func rawValue(_ raw: HealthSampleRaw) -> String {
        if raw.hkType == TrainingTypes.sleep {
            let stages = [0: "卧床", 1: "睡眠（未分期）", 2: "清醒", 3: "核心睡眠", 4: "深睡", 5: "REM"]
            let stage = raw.value.isFinite && (0...5).contains(raw.value) ? stages[Int(raw.value)] ?? "未知阶段" : "未知阶段"
            guard raw.endAt >= raw.startAt else { return "\(stage) · 时段无效" }
            return "\(stage) · \(TrainingText.number((Double(raw.endAt) - Double(raw.startAt)) / 60, unit: "分钟"))"
        }
        return TrainingText.number(raw.unit == "%" ? raw.value * 100 : raw.value, unit: raw.unit)
    }
}
