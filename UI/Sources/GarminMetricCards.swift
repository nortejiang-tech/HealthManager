import SwiftUI
import Charts

struct GarminMetricCards: View {
    @ObservedObject var manager: GarminSyncManager
    @Environment(\.dynamicTypeSize) private var typeSize
    private let metrics: [GarminMetric] = [.bodyBattery, .stress, .sleep, .hrv]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HMSectionHeading("持续健康")
                Spacer()
                if !typeSize.isAccessibilitySize {
                    Text("GARMIN").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                }
            }
            if !manager.isConfigured {
                NavigationLink { SettingsView() } label: {
                    Label("在设置中连接佳明", systemImage: "link")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(metrics, id: \.self) { metric in
                    NavigationLink { GarminMetricDetailView(manager: manager, metric: metric) } label: {
                        metricCard(metric)
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("garmin-card-\(metric.rawValue)")
                }
            }
            GarminReadinessAvailabilityView()
        }
        .task { await manager.load() }
    }

    private func metricCard(_ metric: GarminMetric) -> some View {
        let selection = GarminPresentation(metric: metric, records: manager.records)
        return VStack(alignment: .leading, spacing: 10) {
            Label(metric == .stress ? "压力" : metric.title, systemImage: metric.symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(metric.accent.color)
            HStack(alignment: .center) {
                if metric == .hrv {
                    Text(selection.value.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                    Text("ms").font(.caption).foregroundStyle(.secondary)
                } else {
                    HMScoreRing(value: selection.value, accent: metric.accent, label: "0–100")
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 102, alignment: .leading)
            Text(selection.displayed?.date ?? "等待同步")
                .font(.caption).foregroundStyle(.secondary)
            Text(selection.status).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .hmCard(accent: metric.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title)，\(selection.value.map { String(format: "%.0f", $0) } ?? "暂无数据") \(metric.unit)，\(selection.displayed?.date ?? "")，\(selection.status)")
    }
}

struct GarminReadinessAvailabilityView: View {
    @Environment(\.openURL) private var openURL
    @State private var showOpenFailure = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("CIRQA 支持训练准备程度，但 Garmin 当前公开的 Personal API 尚未提供这项数据。本 App 暂时无法自动读取官方分数。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    openURL(GarminPersonalAPICapabilities.connectURL) { accepted in
                        if !accepted { showOpenFailure = true }
                    }
                } label: {
                    Label("查看 Garmin Connect", systemImage: "arrow.up.right.square")
                        .frame(minHeight: 44)
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("garmin-readiness-connect")
                Text("下方的恢复准备度是本 App 的实验性估计，独立于佳明评分。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("佳明训练准备程度", systemImage: "figure.run.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Personal API 暂未开放").font(.caption).foregroundStyle(.secondary)
            }
        }
        .hmCard(accent: .sky)
        .accessibilityIdentifier("garmin-readiness-unavailable")
        .alert("无法打开 Garmin Connect", isPresented: $showOpenFailure) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请确认手机已安装 Garmin Connect，并稍后重试。")
        }
    }
}

struct GarminMetricDetailView: View {
    @ObservedObject var manager: GarminSyncManager
    let metric: GarminMetric
    private var selection: GarminPresentation { GarminPresentation(metric: metric, records: manager.records) }
    private var records: [GarminMetricRecord] { manager.records.filter { $0.metric == metric }.sorted { $0.date < $1.date } }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(selection.value.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text(metric.unit).foregroundStyle(.secondary)
                }
                Text(selection.status).font(.subheadline)
                if let date = selection.displayed?.date { LabeledContent("数据日期", value: date) }
                if let observed = selection.displayed?.payload?.observedAt {
                    LabeledContent("测量时间", value: Date(timeIntervalSince1970: observed).formatted(date: .abbreviated, time: .shortened))
                }
            }
            if records.contains(where: { $0.payload?.primary != nil }) {
                Section("已记录的每日值") {
                    Chart(records) { record in
                        if let value = record.payload?.primary, let date = Self.dayFormatter.date(from: record.date) {
                            PointMark(x: .value("日期", date), y: .value(metric.title, value))
                                .foregroundStyle(metric.accent.color).symbolSize(38)
                        }
                    }
                    .frame(height: 180)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                    .accessibilityLabel("\(metric.title)每日已记录观测；缺测留空")
                }
            }
            if metric == .bodyBattery, let points = selection.displayed?.payload?.points, !points.isEmpty {
                Section("当日分段观测") {
                    Chart(Array(points.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("时间", Date(timeIntervalSince1970: point.timestamp)), y: .value("身体电量", point.value))
                            .foregroundStyle(metric.accent.color)
                    }.frame(height: 170).chartYScale(domain: 0...100)
                    Text("接口返回分段报告中的有效点，不代表实时连续曲线。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("最近同步") {
                if let latest = selection.latestAttempt {
                    LabeledContent("请求日期", value: latest.date)
                    LabeledContent("请求时间", value: latest.lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("结果", value: latest.state == "available" ? "已取得数据" : latest.state == "error" ? "请求未完成" : "云端暂无数据")
                } else { Text("尚无同步记录") }
                NavigationLink("连接管理") { SettingsView() }
            }
            Section("指标说明") {
                Text(metric.explanation).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(metric.title)
        .task { await manager.load() }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension GarminMetric {
    var accent: HMAccent {
        switch self { case .bodyBattery: return .jade; case .stress: return .amber; case .sleep: return .lavender; case .hrv: return .coral }
    }
    var symbol: String {
        switch self { case .bodyBattery: return "battery.100percent"; case .stress: return "waveform.path"; case .sleep: return "moon.stars.fill"; case .hrv: return "heart.fill" }
    }
    var explanation: String {
        switch self {
        case .bodyBattery: return "Body Battery 为 Garmin 官方指标。卡片显示所选日期分段报告的最后有效点，不是实时流，也不是训练准备程度。"
        case .stress: return "压力是所选日期的官方每日摘要。与 Garmin Connect 对照时，应比较同一天的摘要，而非瞬时压力。"
        case .sleep: return "展示 Garmin 返回的主睡眠官方总分。未返回总分时不使用分项替代；睡眠修正会在后续同步中更新。"
        case .hrv: return "Garmin 夜间 HRV 按厂商定义展示，单位 ms；与 Apple 健康的 SDNN 分开保存，不拼接为同一数值或趋势。"
        }
    }
}
