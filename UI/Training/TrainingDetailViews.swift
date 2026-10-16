import SwiftUI

struct TrainingSessionDetail: View {
    let session: TrainingSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrainingPanel(title: WorkoutsView.label(for: session.activityType), icon: "figure.run") {
                    Text(session.start, format: .dateTime.year().month().day().hour().minute())
                    TrainingStatRow(label: "距离", value: TrainingText.number(session.distanceKm, unit: "km"))
                    TrainingStatRow(label: "有效运动时长", value: TrainingText.number(session.minutes, unit: "分钟"))
                    TrainingStatRow(label: "平均配速", value: TrainingText.pace(session.paceSecondsPerKm))
                    TrainingStatRow(label: "时间加权心率", value: TrainingText.number(session.averageHeartRate, unit: "bpm"))
                    TrainingStatRow(label: "观测峰值心率", value: TrainingText.number(session.peakHeartRate, unit: "bpm"))
                    TrainingStatRow(label: "心率时间覆盖", value: TrainingText.number(session.heartCoverage * 100, unit: "%"))
                    Text("来源：\(session.sourceName)").font(.footnote).foregroundStyle(.secondary)
                }
                TrainingPanel(title: "负荷与恢复依据", icon: "waveform.path.ecg") {
                    TrainingStatRow(label: "心率负荷（实验）", value: TrainingText.number(session.load, unit: "bpm·min"))
                    TrainingStatRow(label: "个人静息基准", value: TrainingText.number(session.restingReference, unit: "bpm"))
                    Text(session.restingMethod).font(.caption).foregroundStyle(.secondary)
                    TrainingStatRow(label: "结束后1分钟心率下降", value: TrainingText.number(session.recovery60, unit: "bpm"))
                    TrainingStatRow(label: "结束后2分钟心率下降", value: TrainingText.number(session.recovery120, unit: "bpm"))
                    ForEach(session.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(HMColors.warning) }
                    Text("负荷仅积分已支持的心率时段，每个读数最多支持30秒。恢复读数取目标时刻±15秒内最近的同来源样本；恢复姿势和是否走动未知。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(HMColors.background).navigationTitle("训练详情")
    }
}

struct TrainingHealthDetail: View {
    let metric: TrainingHealthMetric
    var body: some View {
        ScrollView {
            TrainingPanel(title: metric.title, icon: "chart.xyaxis.line") {
                Text(TrainingText.number(metric.value, unit: metric.unit)).font(.largeTitle.weight(.semibold))
                Text("最近测量：\(TrainingText.time(metric.measuredOn))").font(.caption).foregroundStyle(.secondary)
                TrainingPointChart(points: metric.history, label: "近8周 · \(metric.unit)", color: HMColors.confirmed)
                Text("按已有日汇总或原始读数展示，不补缺测。来源和测量条件变化会影响可比性。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(HMColors.background).navigationTitle(metric.title)
    }
}

struct TrainingMethodView: View {
    let readiness: TrainingReadiness?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TrainingPanel(title: TrainingReadiness.version, icon: "flask") {
                        Text("恢复参考分 = 100 − 睡眠扣分 − 夜间恢复信号扣分 − 近期训练影响，结果限制在0–100。HRV与睡眠心率共同形成一组信号，取较强的标准化偏离，不重复叠加扣分。")
                        Text("这些权重、8小时睡眠目标与时间衰减是第一版实验参数，尚未经过你的长期表现校准。它不是疾病、受伤概率或运动许可。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("夜间信号充分、只有负荷缺失时，按负荷扣分可能为0–15计算分数范围，保留缺失原因；不是统计置信区间。夜间信号不足时不给分。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let readiness {
                        TrainingPanel(title: "本次输入与计算", icon: "list.bullet.rectangle") {
                            ForEach(readiness.factors) { factor in
                                VStack(alignment: .leading, spacing: 6) {
                                    TrainingStatRow(label: factor.title, value: factor.value)
                                    Text("扣分：\(TrainingText.number(factor.penalty))").font(.caption.weight(.semibold))
                                    Text(factor.detail).font(.footnote).foregroundStyle(.secondary)
                                }.padding(.vertical, 6)
                            }
                            ForEach(readiness.missingReasons, id: \.self) { Text("待补：\($0)").font(.footnote).foregroundStyle(HMColors.warning) }
                        }
                    }
                    TrainingPanel(title: "数据可信度", icon: "checkmark.shield") {
                        Text("评分需要本晚至少3个HRV、12个睡眠心率样本，两者采样跨度均至少1小时，以及此前42天内至少14个同来源有效夜晚。单点分数还需要完整近期负荷。主睡眠超过30小时不计算。这些覆盖门槛同样属于实验参数。")
                        Text("缺测、来源改变、阶段冲突和训练心率空档不会填成恢复良好。覆盖可用只表示输入满足本版门槛，不代表医学准确度；样本稀疏、漏戴或漏同步仍可能影响结果。")
                        Text("每次原始记录变化会触发重新计算；页面可见时每15分钟刷新时间推算。数据仍取决于手表到Apple健康的同步，计算时间不等于测量时间。")
                    }.font(.footnote)
                    TrainingPanel(title: "基础数据方法", icon: "function") {
                        Text("配速：有效运动时长÷距离。心率负荷：Σ max(心率−个人静息基准, 0)×覆盖分钟，单位bpm·min。静息基准优先此前28天同来源至少7天的静息心率；不足时明确使用至少7晚的睡眠心率基准。")
                        Text("夜间HRV为主睡眠内SDNN中位数，与全天均值分开。睡眠区间去重并选择主睡眠，午睡不替代主睡眠。停跑后心率下降为结束读数减去1／2分钟后的读数，可为负值。")
                        Text("能力进步需要相似训练中的配速与心率共同支持。训练负荷高不等于能力更强，心肺恢复也不能证明肌肉和关节已经恢复。")
                    }.font(.footnote)
                    TrainingPanel(title: "研究与参考", icon: "book") {
                        Link("心率用于训练状态监测", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC3936188/")!)
                        Link("HRV指导训练的系统综述", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/34639599/")!)
                        Link("心率恢复与训练状态", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/22357753/")!)
                        Link("运动与睡眠共识", destination: URL(string: "https://bjsm.bmj.com/content/55/7/356")!)
                    }.font(.subheadline)
                }.padding(20)
            }.background(HMColors.background)
            .navigationTitle("计算依据与可信度")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("training-method-done")
                }
            }
        }
    }
}
