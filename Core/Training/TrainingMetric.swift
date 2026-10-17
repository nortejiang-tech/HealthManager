import Foundation
import HealthKit

/// One identifier, unit and definition shared by every entry point.
enum TrainingMetric: String, CaseIterable, Identifiable, Sendable {
    case readiness, nightHRV, sleepHeart, mainSleep, load
    case vo2, runPace, runHeart, recovery60, recovery120
    case steps, distance, activeEnergy, exercise, stand, flights, runDistance, runMinutes
    case heart, restingHeart, dayHRV, totalSleep, coreSleep, deepSleep, remSleep
    case weight, bodyFat, leanMass, bmi, respiratory, oxygen, systolic, diastolic, temperature
    var id: String { rawValue }
    var title: String {
        switch self {
        case .readiness: return "恢复准备度"
        case .nightHRV: return "夜间 HRV"
        case .sleepHeart: return "睡眠心率"
        case .mainSleep: return "主睡眠时长"
        case .load: return "心率负荷 · 实验"
        case .vo2: return "VO₂max · 设备估计"
        case .runPace: return "跑步配速"
        case .runHeart: return "跑步平均心率"
        case .recovery60: return "运动后1分钟心率下降"
        case .recovery120: return "运动后2分钟心率下降"
        case .steps: return "步数"
        case .distance: return "步行与跑步距离"
        case .activeEnergy: return "活动能量"
        case .exercise: return "Apple 锻炼分钟"
        case .stand: return "站立分钟"
        case .flights: return "爬楼层数"
        case .runDistance: return "已记录跑步距离"
        case .runMinutes: return "已记录跑步时长"
        case .heart: return "心率"
        case .restingHeart: return "静息心率"
        case .dayHRV: return "全天 HRV"
        case .totalSleep: return "总睡眠时长"
        case .coreSleep: return "主睡眠 · 核心阶段"
        case .deepSleep: return "主睡眠 · 深睡阶段"
        case .remSleep: return "主睡眠 · REM 阶段"
        case .weight: return "体重"
        case .bodyFat: return "体脂率"
        case .leanMass: return "瘦体重"
        case .bmi: return "BMI"
        case .respiratory: return "呼吸频率"
        case .oxygen: return "血氧饱和度"
        case .systolic: return "收缩压"
        case .diastolic: return "舒张压"
        case .temperature: return "体温"
        }
    }
    var unit: String {
        switch self {
        case .readiness: return "分 / 100"
        case .nightHRV, .dayHRV: return "ms"
        case .sleepHeart, .runHeart, .heart, .restingHeart, .recovery60, .recovery120: return "bpm"
        case .mainSleep, .totalSleep, .coreSleep, .deepSleep, .remSleep: return "小时"
        case .load: return "bpm·min"
        case .vo2: return "ml/kg/min"
        case .runPace: return "秒/km"
        case .steps: return "步"
        case .distance, .runDistance: return "km"
        case .activeEnergy: return "kcal"
        case .exercise, .stand, .runMinutes: return "分钟"
        case .flights: return "层"
        case .weight, .leanMass: return "kg"
        case .bodyFat, .oxygen: return "%"
        case .bmi: return "kg/m²"
        case .respiratory: return "次/分"
        case .systolic, .diastolic: return "mmHg"
        case .temperature: return "℃"
        }
    }
    var group: String {
        switch self {
        case .readiness, .nightHRV, .sleepHeart, .heart, .restingHeart, .dayHRV, .load: return "心率与恢复"
        case .vo2, .runPace, .runHeart, .recovery60, .recovery120: return "心肺与跑步表现"
        case .steps, .distance, .activeEnergy, .exercise, .stand, .flights, .runDistance, .runMinutes: return "活动量"
        case .mainSleep, .totalSleep, .coreSleep, .deepSleep, .remSleep: return "睡眠"
        case .weight, .bodyFat, .leanMass, .bmi: return "身体关联"
        default: return "其他生理参数"
        }
    }
    static let groups = ["心率与恢复", "心肺与跑步表现", "活动量", "睡眠", "身体关联", "其他生理参数"]
    var isBar: Bool { group == "活动量" || self == .load }
    var daily: (table: String, column: String, multiplier: Double)? {
        let activity = "activity_metrics_daily", body = "body_metrics_daily"
        switch self {
        case .steps: return (activity, "step_count", 1)
        case .distance: return (activity, "distance_m", 0.001)
        case .activeEnergy: return (activity, "active_energy_kcal", 1)
        case .exercise: return (activity, "exercise_minutes", 1)
        case .stand: return (activity, "stand_minutes", 1)
        case .flights: return (activity, "flights_climbed", 1)
        case .restingHeart: return (activity, "resting_hr_bpm", 1)
        case .dayHRV: return (activity, "hrv_ms", 1)
        case .totalSleep: return (activity, "sleep_seconds", 1 / 3600)
        case .weight: return (body, "weight_kg", 1)
        case .bodyFat: return (body, "body_fat_pct", 100)
        case .leanMass: return (body, "lean_mass_kg", 1)
        case .bmi: return (body, "bmi", 1)
        default: return nil
        }
    }
    var rawType: HKQuantityTypeIdentifier? {
        switch self {
        case .vo2: return .vo2Max
        case .respiratory: return .respiratoryRate
        case .oxygen: return .oxygenSaturation
        case .systolic: return .bloodPressureSystolic
        case .diastolic: return .bloodPressureDiastolic
        case .temperature: return .bodyTemperature
        default: return nil
        }
    }
    var sampleType: String? {
        if let type = rawType { return type.rawValue }
        let quantity: HKQuantityTypeIdentifier?
        switch self {
        case .steps: quantity = .stepCount
        case .distance: quantity = .distanceWalkingRunning
        case .activeEnergy: quantity = .activeEnergyBurned
        case .exercise: quantity = .appleExerciseTime
        case .stand: quantity = .appleStandTime
        case .flights: quantity = .flightsClimbed
        case .restingHeart: quantity = .restingHeartRate
        case .heart, .sleepHeart: quantity = .heartRate
        case .dayHRV, .nightHRV: quantity = .heartRateVariabilitySDNN
        case .weight: quantity = .bodyMass
        case .bodyFat: quantity = .bodyFatPercentage
        case .leanMass: quantity = .leanBodyMass
        case .bmi: quantity = .bodyMassIndex
        case .mainSleep, .totalSleep, .coreSleep, .deepSleep, .remSleep: return TrainingTypes.sleep
        default: quantity = nil
        }
        return quantity?.rawValue
    }
    var definition: String {
        switch self {
        case .readiness: return "每日主睡眠结束时评估；v2 使用原实验权重。历史为按当前已入库记录回溯重算，并非当时已保存的分数。"
        case .nightHRV: return "主睡眠内同来源 SDNN 中位数；与全天 HRV 分开。"
        case .sleepHeart: return "主睡眠内同来源心率中位数。"
        case .mainSleep: return "18:00–次日18:00内识别的主要夜间睡眠，去重并排除清醒；午睡不并入。"
        case .coreSleep, .deepSleep, .remSleep: return "主睡眠内该阶段去重后的时长；缺少阶段标注时留空。设备睡眠阶段是估计。"
        case .load: return "已覆盖分钟 × 超出个人静息基准的心率；只累计可计算部分，单位 bpm·min。缺测不当作零负荷。"
        case .vo2: return "保留每次设备估计的实际测量日期和来源。体重变化也会影响按公斤标准化的值；不生成排名。"
        case .runPace: return "每次跑步有效时长÷距离；比较需同时看心率、距离与来源，不等同跑步经济性。"
        case .runHeart: return "跑步期间时间加权平均心率，要求同来源心率覆盖≥70%，暂停与重叠可识别。"
        case .recovery60, .recovery120: return "结束附近读数减去1／2分钟后读数，目标时刻±15秒。可为负值；恢复姿势和走动未知。"
        case .heart: return "按来源分开的30分钟心率中位数；保留日内时间，不把走动或压力解释为恢复。"
        case .totalSleep: return "沿用日汇总的睡眠去重口径，含该日记录的睡眠；不等于主睡眠，也不是睡眠效率。"
        case .dayHRV, .restingHeart: return "沿用本机日汇总平均值；可包含多个来源，不与同来源夜间中位数混用。"
        case .weight, .bodyFat, .leanMass, .bmi: return "沿用本机日汇总平均值；缺测留空。数值变化本身不标记为健康改善或恶化。"
        case .exercise: return "Apple 锻炼分钟日汇总，与 Workout 记录的时长不同。"
        case .distance: return "步行与跑步合计的日汇总距离，不等于跑步训练距离。"
        case .runDistance, .runMinutes: return "按已同步、去重的跑步记录统计；无记录不证明未运动，缺少距离不会填0。"
        default: return daily != nil ? "沿用本机日汇总与去重规则。只展示已有记录，不填补缺测。" : "按真实测量时刻和来源展示；单位校验通过的记录才进入趋势。"
        }
    }
}

extension TrainingSnapshot {
    func series(for metric: TrainingMetric) -> [TrainingMetricValue] {
        if let values = parameters[metric.id] { return values }
        if [.runPace, .runHeart, .recovery60, .recovery120].contains(metric) {
            return sessions.sorted { $0.start < $1.start }.compactMap { session in
                let value: Double?
                switch metric {
                case .runPace: value = session.isRun ? session.paceSecondsPerKm : nil
                case .runHeart: value = session.isRun ? session.averageHeartRate : nil
                case .recovery60: value = session.recovery60
                default: value = session.recovery120
                }
                return value.map { TrainingMetricValue(id: session.id, date: session.start, value: $0,
                    source: session.source, sourceName: session.sourceName) }
            }
        }
        return days.compactMap { day in
            let value: Double?
            switch metric {
            case .nightHRV: value = day.night?.hrv
            case .sleepHeart: value = day.night?.heartRate
            case .mainSleep: value = day.night?.hours
            case .coreSleep: value = day.night?.stageHours[3]
            case .deepSleep: value = day.night?.stageHours[4]
            case .remSleep: value = day.night?.stageHours[5]
            case .load: value = day.recordedLoad
            case .runDistance: value = day.runKm > 0 ? day.runKm : nil
            case .runMinutes: value = day.runMinutes > 0 ? day.runMinutes : nil
            default: value = nil
            }
            let isNight = [.nightHRV, .sleepHeart, .mainSleep, .coreSleep, .deepSleep, .remSleep].contains(metric)
            return value.map { TrainingMetricValue(id: day.key, date: isNight ? (day.night?.end ?? day.date) : day.date, value: $0,
                source: isNight ? (day.night?.source ?? "unknown") : "recorded-workouts",
                sourceName: isNight ? (day.night?.source ?? "来源未标注") : "已记录运动汇总（可能含多来源）") }
        }
    }
}
