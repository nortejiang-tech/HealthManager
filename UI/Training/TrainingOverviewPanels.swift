import SwiftUI

struct TrainingOverviewReadiness: View {
    let snapshot: TrainingSnapshot
    let isStale: Bool
    let onMethod: () -> Void
    private var value: TrainingReadiness { snapshot.readiness }
    var body: some View {
        TrainingPanel(title: "恢复准备度", icon: "waveform.path.ecg") {
            Text("实验性估计 · 最近一次睡后评估").font(.caption).foregroundStyle(.secondary)
            Text(isStale ? "本次未评估" : TrainingText.readiness(value))
                .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(HMColors.estimate)
                .accessibilityIdentifier("training-readiness-score")
            Text("评估时点：\(TrainingText.time(value.observedAt))").font(.caption)
            if !isStale, let score = value.score, let previous = value.previousScore, let date = value.previousDate {
                Text("较上次（\(date.formatted(.dateTime.month().day()))）\(String(format: "%+d", score - previous)) 分")
                    .font(.subheadline.weight(.semibold))
            }
            if let range = value.referenceRange {
                Text("过去28天个人常见范围 \(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) 分")
                    .font(.subheadline)
                Text("此前\(value.referenceCount)个同来源单点的P25–P75，不是医学正常范围。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("个人常见范围：需过去28天内至少14个同来源单点，当前\(value.referenceCount)个。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.possibleRange != nil {
                Text("仅训练负荷不全，显示可能范围；不取中点或计算精确差值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.score == nil && value.possibleRange == nil,
               let last = snapshot.readinessHistory.last(where: { $0.assessment.score != nil || $0.assessment.possibleRange != nil }) {
                Text("上次有效评估：\(TrainingText.time(last.date)) · \(TrainingText.readiness(last.assessment))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TrainingReadinessChart(points: Array(snapshot.readinessHistory.suffix(7)), compact: true)
            Text("近7天 · 0–100分 · 缺测留空").font(.caption).foregroundStyle(.secondary)
            ForEach(value.missingReasons.prefix(2), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Button("查看计算依据与缺失项", action: onMethod).font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("training-readiness-evidence")
        }
    }
}

struct TrainingStateInputsPanel: View {
    let snapshot: TrainingSnapshot
    var body: some View {
        TrainingPanel(title: "状态构成", icon: "moon.zzz") {
            ForEach([TrainingMetric.mainSleep, .nightHRV, .sleepHeart]) { metric in
                NavigationLink { TrainingMetricDetail(metric: metric) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        TrainingStatRow(label: metric.title, value: snapshot.series(for: metric).last.map { TrainingText.metricValue($0.value, metric) } ?? "暂无记录")
                        Text(reference(metric)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
        }
    }
    private func reference(_ metric: TrainingMetric) -> String {
        guard let night = snapshot.latestNight else { return "等待可识别的主睡眠记录" }
        let base = snapshot.days.compactMap(\.night).filter {
            $0.source == night.source && $0.end < night.start && $0.start >= night.start.addingTimeInterval(-42 * 86400) && $0.qualifiesForBaseline
        }
        let values: [Double] = base.compactMap {
            metric == .mainSleep ? $0.hours : (metric == .nightHRV ? $0.hrv : $0.heartRate)
        }
        let baseline = TrainingCalculator.median(values)
        let current = metric == .mainSleep ? night.hours : (metric == .nightHRV ? night.hrv : night.heartRate)
        let date = TrainingText.time(night.end)
        guard base.count >= 14, let baseline, let current else { return "\(date) · 同来源基线\(base.count)晚，尚不足14晚" }
        return "\(date) · 个人中位数 \(TrainingText.number(baseline, unit: metric.unit)) · 差值 \(String(format: "%+.1f", current - baseline)) \(metric.unit)"
    }
}

struct TrainingCapabilityPanel: View {
    let snapshot: TrainingSnapshot
    private var points: [TrainingMetricValue] { snapshot.series(for: .vo2) }
    var body: some View {
        TrainingPanel(title: "心肺能力", icon: "lungs") {
            NavigationLink { TrainingMetricDetail(metric: .vo2) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VO₂max · 设备估计").font(.subheadline.weight(.semibold))
                    Text(points.last.map { TrainingText.metricValue($0.value, .vo2) } ?? "暂无记录")
                        .font(.title2.weight(.semibold)).foregroundStyle(.primary)
                    if let latest = points.last {
                        Text("\(TrainingText.time(latest.date)) · \(latest.sourceName)").font(.caption).foregroundStyle(.secondary)
                    }
                    TrainingMetricChart(metric: .vo2, points: points, compact: true)
                    Text("4周：\(change(28))\n8周：\(change(56))").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            Text("按真实测量点展示；来源或设备变化单独标色。按公斤标准化的值也受体重影响。")
                .font(.caption).foregroundStyle(.secondary)
        }
        TrainingRunComparisonPanel(snapshot: snapshot)
    }
    private func change(_ days: Int) -> String {
        let begin = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: snapshot.calculatedAt))!
        return TrainingText.change(points.filter { $0.date >= begin }, metric: .vo2)
    }
}

struct TrainingRunComparisonPanel: View {
    let snapshot: TrainingSnapshot
    var body: some View {
        TrainingPanel(title: "近8周相似跑步表现", icon: "figure.run") {
            if let c = snapshot.comparison {
                Text("约\(TrainingText.number(c.distanceKm, unit: "km")) · 同来源 · 距离差≤10%")
                    .font(.caption).foregroundStyle(.secondary)
                TrainingStatRow(label: "近期配速", value: TrainingText.pace(c.recentPace))
                TrainingStatRow(label: "此前配速", value: TrainingText.pace(c.earlierPace))
                TrainingStatRow(label: "配速差", value: String(format: "%+.0f 秒/km", c.recentPace - c.earlierPace))
                TrainingStatRow(label: "近期／此前心率", value: "\(TrainingText.number(c.recentHeart)) / \(TrainingText.number(c.earlierHeart)) bpm")
                if let a = c.recentHeart, let b = c.earlierHeart {
                    TrainingStatRow(label: "心率差", value: String(format: "%+.1f bpm", a - b))
                }
                Text("近期\(c.recentCount)次：\(dates(c.recentStart, c.recentEnd))\n此前\(c.earlierCount)次：\(dates(c.earlierStart, c.earlierEnd))\n来源：\(c.sourceName)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach([TrainingMetric.runPace, .runHeart]) { metric in
                    NavigationLink { TrainingMetricDetail(metric: metric) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(metric.title) · \(metric.unit)").font(.caption)
                            TrainingMetricChart(metric: metric, points: comparablePoints(metric, c), compact: true)
                        }
                    }.buttonStyle(.plain)
                }
                Text("配速按总时长÷总距离，心率取各次均值的中位数；路线、气温、运动目的未控制，不等于同心率配速或跑步经济性。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("至少4次同来源、相似距离且心率可用的跑步后，展示配速与心率的联合比较。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("查看跑步配速记录", destination: TrainingMetricDetail(metric: .runPace))
            }
        }
    }
    private func comparablePoints(_ metric: TrainingMetric, _ c: TrainingRunComparison) -> [TrainingMetricValue] {
        let ids = Set(snapshot.sessions.filter {
            $0.isRun && $0.averageHeartRate != nil && $0.source == c.source && abs(($0.distanceKm ?? -100) - c.distanceKm) <= c.distanceKm * 0.1
        }.map(\.id))
        return snapshot.series(for: metric).filter { ids.contains($0.id) }
    }
    private func dates(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "暂无日期" }
        return "\(start.formatted(.dateTime.month().day()))–\(end.formatted(.dateTime.month().day()))"
    }
}

struct TrainingVolumePanel: View {
    let snapshot: TrainingSnapshot
    var body: some View {
        TrainingPanel(title: "近期运动量", icon: "chart.bar") {
            let complete = Array(snapshot.days.dropLast())
            let recent = Array(complete.suffix(7))
            let prior = Array(complete.dropLast(7).suffix(28))
            let minutes = recent.map(\.runMinutes).reduce(0, +)
            let baseline = prior.map(\.runMinutes).reduce(0, +) / 4
            let hasRuns = recent.contains { $0.runMinutes > 0 }
            TrainingStatRow(label: "近7个完整日 · 已记录跑步", value: hasRuns ? TrainingText.number(minutes, unit: "分钟") : "暂无记录")
            TrainingStatRow(label: "已知距离", value: recent.contains { $0.runKm > 0 } ? TrainingText.number(recent.map(\.runKm).reduce(0, +), unit: "km") : "暂无距离")
            let begin = recent.first?.date ?? snapshot.calculatedAt
            let end = Calendar.current.startOfDay(for: snapshot.calculatedAt)
            Text("\(snapshot.sessions.filter { $0.isRun && $0.start >= begin && $0.start < end }.count)次跑步 · \(begin.formatted(.dateTime.month().day()))–\(recent.last?.date.formatted(.dateTime.month().day()) ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if hasRuns, let percent = TrainingTrendMath.percentChange(current: minutes, baseline: baseline) {
                Text("比此前4个完整7天窗口的均值 \(String(format: "%+.0f%%", percent))（\(Int(baseline.rounded()))分钟）")
                    .font(.subheadline)
            } else { Text("此前均值为0或不足，暂不计算百分比。").font(.caption).foregroundStyle(.secondary) }
            Text("仅统计已记录跑步；可能有漏记，\(recent.map(\.missingDistanceCount).reduce(0, +))次距离缺失。不同运动类型不换算为同等负担。")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink("查看运动量趋势", destination: TrainingMetricDetail(metric: .runMinutes))
        }
    }
}
