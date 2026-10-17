import SwiftUI
import GRDB

struct TrainingParameterDirectory: View {
    let snapshot: TrainingSnapshot
    var onlyGroup: String? = nil
    @State private var query = ""
    var body: some View {
        TextField("搜索参数", text: $query).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("training-parameter-search")
        if onlyGroup == nil {
            TrainingPanel(title: "运动记录", icon: "figure.run") {
                NavigationLink("全部运动记录与手工补录", destination: WorkoutsView())
                    .accessibilityIdentifier("training-workouts")
                Text("时间、距离、配速、消耗、心率与覆盖情况在每次运动中查看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(TrainingMetric.groups.filter { onlyGroup == nil || $0 == onlyGroup }, id: \.self) { group in
            let metrics = TrainingMetric.allCases.filter { $0.group == group && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
            if !metrics.isEmpty {
                TrainingPanel(title: group, icon: "list.bullet.rectangle") {
                    ForEach(metrics) { metric in
                        NavigationLink { TrainingMetricDetail(metric: metric) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                TrainingStatRow(label: metric.title, value: latestValue(metric))
                                if let latest = snapshot.series(for: metric).last {
                                    Text("\(TrainingText.observationTime(latest)) · \(latest.sourceName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if metric == .readiness {
                                    Text("\(TrainingText.time(snapshot.readiness.observedAt)) · 实验估计")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("training-parameter-\(metric.id)")
                    }
                }
            }
        }
        if onlyGroup == nil && query.isEmpty {
            TrainingPanel(title: "待接入的跑步参数", icon: "sensor") {
                Text("步频、步幅、触地时间、垂直振幅、跑步功率、分段数据")
                    .font(.subheadline)
                Text("当前采集目录尚未接入；不生成估算数值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func latestValue(_ metric: TrainingMetric) -> String {
        if metric == .readiness { return TrainingText.readiness(snapshot.readiness) }
        return snapshot.series(for: metric).last.map { TrainingText.metricValue($0.value, metric) } ?? "近8周暂无记录"
    }
}

/// The canonical destination used by Training and the global dashboard.
struct TrainingMetricDetail: View {
    let metric: TrainingMetric
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sync: SyncEngine
    @State private var snapshot: TrainingSnapshot?
    @State private var error: String?
    @State private var window = 28
    @State private var revision = 0
    @State private var observation: AnyDatabaseCancellable?
    private var key: String { "\(revision)-\(sync.aggregationTick)-\(environment.localDataTick)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrainingWindowPicker(window: $window)
                if let config = metric.extendedHistoryConfig {
                    HStack {
                        Text("更长历史 · 可滚动与缩放").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        NavigationLink("年") {
                            MetricDetailView(config: config, initialPeriod: .year, showsDirectionalTrend: false)
                        }.buttonStyle(.bordered).accessibilityIdentifier("training-extended-year")
                    }
                }
                if let error {
                    Text("参数暂未更新：\(error)").foregroundStyle(HMColors.warning)
                    Button("重新读取") { revision &+= 1 }
                } else if let snapshot {
                    TrainingMetricContent(snapshot: snapshot, metric: metric, window: window)
                    if metric == .readiness {
                        NavigationLink("完整计算依据", destination: TrainingMethodView(readiness: snapshot.readiness))
                    }
                    Text("本次读取／回溯计算：\(TrainingText.time(snapshot.calculatedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if metric.sampleType != nil {
                        NavigationLink("相关原始记录", destination: TrainingRawRecordsView(metric: metric))
                            .accessibilityIdentifier("training-raw-records")
                    }
                    NavigationLink("来源与数据质量", destination: DataQualityDetailView())
                } else { ProgressView("正在读取参数…").frame(maxWidth: .infinity, minHeight: 200) }
            }.padding(20)
        }.background(HMColors.background)
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("training-metric-\(metric.id)")
        .task(id: key) { await load() }
        .refreshable { await load() }
        .onAppear {
            guard observation == nil else { return }
            observation = DatabaseRegionObservation(tracking: Table("health_samples_raw"), Table("activity_metrics_daily"), Table("body_metrics_daily"))
                .start(in: environment.database.pool, onError: { failure in
                    Task { @MainActor in error = failure.localizedDescription }
                }, onChange: { _ in Task { @MainActor in revision &+= 1 } })
        }
        .onDisappear { observation?.cancel(); observation = nil }
    }
    @MainActor private func load() async {
        do {
            let loaded = try await TrainingSnapshotLoader.load(database: environment.database)
            guard !Task.isCancelled else { return }
            snapshot = loaded; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct TrainingActivityParameters: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var snapshot: TrainingSnapshot?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot { TrainingParameterDirectory(snapshot: snapshot, onlyGroup: "活动量") }
                else if let error { Text(error) }
                else { ProgressView("正在读取活动参数…") }
            }.padding(20)
        }.background(HMColors.background).navigationTitle("活动量参数")
        .task {
            do { snapshot = try await TrainingSnapshotLoader.load(database: environment.database) }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension TrainingMetric {
    /// Reuse the existing daily-series reader and zoom UI for previously supported metrics.
    /// This does not extend the experimental readiness reconstruction beyond eight weeks.
    var extendedHistoryConfig: MetricDetailConfig? {
        switch self {
        case .steps: return .steps
        case .distance: return .distance
        case .activeEnergy: return .activeKcal
        case .restingHeart: return .restingHR
        case .totalSleep: return .sleep
        case .weight: return .weight
        case .bodyFat: return .bodyFat
        case .bmi: return .bmi
        default: return nil
        }
    }
}
