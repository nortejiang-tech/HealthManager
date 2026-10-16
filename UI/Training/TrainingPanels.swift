import SwiftUI
import Charts

struct TrainingReadinessCard: View {
    let readiness: TrainingReadiness
    let isStale: Bool
    let onMethod: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Label("恢复参考", systemImage: "waveform.path.ecg").font(.headline)
                    HMEvidenceTag(tone: .estimate, text: "实验性", systemImage: "flask")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack {
                    Label("恢复参考", systemImage: "waveform.path.ecg").font(.headline)
                    Spacer()
                    HMEvidenceTag(tone: .estimate, text: "实验性", systemImage: "flask")
                }
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    scoreValueText
                    Text("/ 100").foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    scoreValueText
                    Text("/ 100").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Text(isStale ? "数据未更新，暂不展示当前评分" : readiness.credibility)
                .font(.subheadline.weight(.semibold))
            if readiness.possibleRange != nil {
                Text("仅负荷缺失时，以未知扣分0–15给出可能范围；不是统计置信区间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("同来源有效基线 \(readiness.baselineNights) 晚 · 主睡眠结束 \(TrainingText.time(readiness.observedAt))")
                .font(.caption).foregroundStyle(.secondary)
            if readiness.missingReasons.isEmpty {
                ForEach(readiness.factors.filter { ($0.penalty ?? 0) > 0 }.sorted { ($0.penalty ?? 0) > ($1.penalty ?? 0) }.prefix(2)) { factor in
                    Text("\(factor.title)：\(factor.value)").font(.subheadline)
                }
            } else {
                ForEach(readiness.missingReasons.prefix(3), id: \.self) { reason in
                    Label(reason, systemImage: "circle.dotted").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("查看计算依据与缺失项", action: onMethod)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("training-readiness-evidence")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMColors.estimate.opacity(0.07), in: RoundedRectangle(cornerRadius: HMRadius.panel))
        .overlay(RoundedRectangle(cornerRadius: HMRadius.panel).stroke(HMColors.estimate.opacity(0.2), lineWidth: 1))
    }

    private var scoreValueText: some View {
        Text(isStale ? "—" : scoreText)
            .font(.system(size: 62, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(HMColors.estimate)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .accessibilityIdentifier("training-readiness-score")
    }

    private var scoreText: String {
        if let score = readiness.score { return String(score) }
        if let range = readiness.possibleRange { return "\(range.lowerBound)–\(range.upperBound)" }
        return "—"
    }
}

struct TrainingPerformancePanel: View {
    let snapshot: TrainingSnapshot
    let window: Int
    var body: some View {
        TrainingPanel(title: "跑步表现", icon: "figure.run") {
            let days = snapshot.recentDays(window)
            let runs = days.reduce(0) { $0 + $1.runMinutes }
            TrainingStatRow(label: "已记录跑量", value: days.contains { $0.runKm > 0 } ? TrainingText.number(days.map(\.runKm).reduce(0, +), unit: "km") : "—")
            TrainingStatRow(label: "已记录跑步时长", value: runs > 0 ? TrainingText.number(runs, unit: "分钟") : "—")
            let missingDistance = days.map(\.missingDistanceCount).reduce(0, +)
            if missingDistance > 0 {
                Text("\(missingDistance)次跑步缺少距离，跑量仅含有距离的记录。")
                    .font(.caption).foregroundStyle(HMColors.warning)
            }
            if days.contains(where: { $0.runKm > 0 }) {
                Chart(days.filter { $0.runKm > 0 }) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("已记录公里", day.runKm))
                        .foregroundStyle(HMColors.confirmed.gradient).cornerRadius(3)
                }
                .frame(height: 135)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .accessibilityLabel("近\(window)天已记录跑量")
            } else { TrainingChartEmpty(text: "暂无可计算距离的跑步记录") }
            if let c = snapshot.comparison {
                Divider()
                Text("近8周约\(TrainingText.number(c.distanceKm, unit: "km"))同距离组 · 最近\(c.recentCount)次与此前\(c.earlierCount)次")
                    .font(.caption).foregroundStyle(.secondary)
                TrainingStatRow(label: "近期配速", value: TrainingText.pace(c.recentPace))
                TrainingStatRow(label: "此前配速", value: TrainingText.pace(c.earlierPace))
                TrainingStatRow(label: "对应心率", value: "\(TrainingText.number(c.recentHeart)) / \(TrainingText.number(c.earlierHeart)) bpm")
                Text("同来源、距离差≤10%的整次记录比较。路线、气温和训练目的仍会影响结果；用于观察个人变化。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("积累至少4次同来源、相似距离且心率可用的跑步后，显示配速与心率联合比较。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TrainingLoadPanel: View {
    let snapshot: TrainingSnapshot
    let window: Int
    var body: some View {
        TrainingPanel(title: "训练负荷 · 参考", icon: "chart.bar.xaxis") {
            let days = snapshot.recentDays(window)
            let missing = days.reduce(0) { $0 + $1.missingLoadCount }
            let loads = days.compactMap(\.recordedLoad)
            TrainingStatRow(label: "已计算部分", value: loads.isEmpty ? "—" : TrainingText.number(loads.reduce(0, +), unit: "bpm·min"))
            if missing > 0 {
                Text("\(missing)次训练缺少可用负荷，累计值仅含已计算部分。")
                    .font(.caption).foregroundStyle(HMColors.warning)
            }
            if !loads.isEmpty {
                Chart(days.filter { $0.recordedLoad != nil }) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("心率负荷", day.recordedLoad!))
                        .foregroundStyle(HMColors.comparison.gradient).cornerRadius(3)
                }
                .frame(height: 135)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            } else { TrainingChartEmpty(text: "需要足够心率覆盖与此前个人静息基准") }
            Text("本版实验性心率积分：高于个人静息基准的心率 × 已覆盖分钟，按所有训练累计。覆盖不足70%、暂停不明或训练重叠时留空。未记录训练的日期不代表休息。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TrainingRecoveryPanel: View {
    let snapshot: TrainingSnapshot
    let window: Int
    @State private var metric = 0
    var body: some View {
        TrainingPanel(title: "恢复趋势", icon: "moon.zzz") {
            if let night = snapshot.latestNight {
                TrainingStatRow(label: "最近主睡眠", value: TrainingText.number(night.hours, unit: "小时"))
                TrainingStatRow(label: "夜间HRV", value: "\(TrainingText.number(night.hrv, unit: "ms")) · \(night.hrvCount)个样本")
                TrainingStatRow(label: "睡眠心率", value: TrainingText.number(night.heartRate, unit: "bpm"))
            }
            Picker("恢复趋势指标", selection: $metric) {
                Text("夜间HRV").tag(0)
                Text("主睡眠时长").tag(1)
                Text("睡眠心率").tag(2)
                Text("跑后1分钟心率下降").tag(3)
            }.pickerStyle(.menu)
            TrainingPointChart(points: recoveryPoints, label: ["夜间HRV（ms）", "主睡眠时长（小时）", "睡眠心率（bpm）", "跑后1分钟心率下降（bpm）"][metric], color: HMColors.estimate)
            Text("夜间HRV按主睡眠内的同来源样本取中位数。点之间留白保留缺测，样本数不代表整晚覆盖。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("日内非训练心率 · 近24小时").font(.subheadline.weight(.semibold))
            TrainingPointChart(points: snapshot.intraday.map {
                TrainingMetricValue(id: String($0.date.timeIntervalSince1970), date: $0.date, value: $0.heartRate)
            }, label: "30分钟中位心率（bpm）", color: HMColors.confirmed, intraday: true)
            Text("每30分钟至少3个样本；排除已记录训练及结束后10分钟、明确活动读数。走动和压力仍可能影响，不能单凭心率判定恢复。")
                .font(.caption).foregroundStyle(.secondary)
            if let run = snapshot.sessions.first(where: \.isRun) {
                Divider()
                TrainingStatRow(label: "最近跑步后1分钟心率下降", value: TrainingText.number(run.recovery60, unit: "bpm"))
                TrainingStatRow(label: "最近跑步后2分钟心率下降", value: TrainingText.number(run.recovery120, unit: "bpm"))
                Text("\(TrainingText.time(run.end)) · 结束附近读数减去恢复读数。负值表示继续升高；需结合是否走动、姿势和结束强度比较。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recoveryPoints: [TrainingMetricValue] {
        let days = snapshot.recentDays(window)
        if metric == 3 {
            guard let start = days.first?.date else { return [] }
            return snapshot.sessions.filter { $0.isRun && $0.start >= start }.compactMap {
                guard let value = $0.recovery60 else { return nil }
                return TrainingMetricValue(id: $0.id, date: $0.end, value: value)
            }
        }
        return days.compactMap { day in
            guard let night = day.night else { return nil }
            let value: Double? = metric == 0 ? night.hrv : (metric == 1 ? night.hours : night.heartRate)
            guard let value else { return nil }
            return TrainingMetricValue(id: day.key, date: day.date, value: value)
        }
    }
}

struct TrainingHealthPanel: View {
    let metrics: [TrainingHealthMetric]
    var body: some View {
        TrainingPanel(title: "心肺与身体", icon: "heart.text.square") {
            if metrics.isEmpty { Text("尚无相关测量；同步后显示已存在的数据和趋势。").foregroundStyle(.secondary) }
            ForEach(metrics) { metric in
                NavigationLink { TrainingHealthDetail(metric: metric) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        TrainingStatRow(label: metric.title, value: TrainingText.number(metric.value, unit: metric.unit))
                        Text("\(metric.measuredOn.formatted(.dateTime.month().day())) · 查看近8周记录")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
            Text("VO₂max保留为设备估计参考；体重变化也影响按公斤标准化的数值。各项按其最近测量日期展示。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TrainingStatRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { Text(label).foregroundStyle(.secondary); Text(value).fontWeight(.semibold) }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
                }
            }
        }.font(.subheadline).monospacedDigit().accessibilityElement(children: .combine)
    }
}

struct TrainingChartEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

struct TrainingPointChart: View {
    let points: [TrainingMetricValue]
    let label: String
    let color: Color
    var intraday = false
    var body: some View {
        if points.isEmpty { TrainingChartEmpty(text: "\(label)：暂无可用记录") }
        else {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Chart(points) { point in
                    PointMark(x: .value("时间", point.date), y: .value(label, point.value))
                        .foregroundStyle(color).symbolSize(intraday ? 14 : 24)
                }
                .frame(height: 120)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYScale(domain: .automatic(includesZero: false))
                .accessibilityLabel("\(label)，\(points.count)个已记录观测点，缺测未补值")
            }
        }
    }
}
