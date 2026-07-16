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
    @State private var hasLoadedSnapshot: Bool = false

    var body: some View {
        List {
            Section("今日数据质量") {
                if let q = todayQuality {
                    HMDecisionLens(
                        title: "数据质量评分",
                        text: "仅反映覆盖、时效和冲突，不代表健康状态判断。",
                        tone: .comparison,
                        systemImage: "checkmark.shield",
                        primaryActionTitle: nil,
                        primaryAction: nil,
                        secondaryActions: []
                    )
                    QualityScoreRow(label: "完整度", value: q.completenessScore)
                    QualityScoreRow(label: "新鲜度", value: q.freshnessScore)
                    QualityScoreRow(label: "冲突检查（高分代表冲突较少）", value: q.conflictScore)
                    if let missingJson = q.missingMetricsJson,
                       let missing = Self.decodeStringArray(missingJson),
                       !missing.isEmpty {
                        HMInformationRow(
                            systemImage: "exclamationmark.triangle",
                            tone: .actionRequired,
                            title: "缺失类型",
                            detail: missing.map(DailyReconciler.humanLabel(for:)).joined(separator: "、")
                        )
                        Text("缺失项不会按 0 参与汇总；同步与对账仍可继续。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if hasLoadedSnapshot {
                    HMEmptyState(
                        title: "今日尚无质量结果",
                        message: "这不代表质量为 0；同步并完成一次数据对账后才会生成评分。",
                        icon: "checkmark.shield",
                        tone: .neutral
                    )
                } else if loadError == nil {
                    ProgressView("正在读取数据质量…")
                }
            }

            Section("数据采集") {
                LabeledContent("原始样本累计", value: hasLoadedSnapshot ? "\(rawSampleCount)" : "—")
                LabeledContent(
                    "最近写入时间",
                    value: hasLoadedSnapshot
                        ? (lastIngest.map { Self.formatter.string(from: $0) } ?? "—")
                        : "—"
                )
            }

            Section("最近同步") {
                if let result = sync.lastResult {
                    LabeledContent("作业类型", value: result.jobType.rawValue)
                    HMEvidenceTag(
                        tone: result.succeeded ? .confirmed : .actionRequired,
                        text: result.succeeded ? "同步完成" : "同步未完成",
                        systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    LabeledContent("样本数", value: "\(result.totalSamples)")
                    LabeledContent("耗时", value: String(format: "%.1fs", result.endedAt.timeIntervalSince(result.startedAt)))
                    if let err = result.errorMessage {
                        HMEditorCallout(
                            title: "同步错误",
                            message: "已成功写入的数据会保留。",
                            tone: .actionRequired,
                            systemImage: "exclamationmark.triangle.fill",
                            detail: err
                        )
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
                Section {
                    HMInlineRecovery(
                        title: "数据质量加载失败",
                        message: "现有数据没有被修改。可在当前页面重新读取。",
                        technicalDetails: err,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
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
                hasLoadedSnapshot = true
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                if let v = value {
                    Text(String(format: "%.0f%%", v * 100))
                        .foregroundStyle(color(for: v))
                        .font(.body.weight(.semibold).monospacedDigit())
                } else {
                    Text("未生成").foregroundStyle(.secondary)
                }
            }
            if let value {
                ProgressView(value: min(max(value, 0), 1))
                    .tint(color(for: value))
                    .accessibilityLabel(label)
                    .accessibilityValue(String(format: "%.0f%%", value * 100))
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for v: Double) -> Color {
        if v >= 0.8 { return HMColors.confirmed }
        if v >= 0.5 { return HMColors.actionRequired }
        return HMColors.actionRequired.opacity(0.85)
    }
}
