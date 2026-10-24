import Foundation
import CryptoKit
import GRDB

enum HealthBriefLoader {
    static let promptVersion = "health-brief-v4"
    static func load(database: DatabaseManager, training: TrainingSnapshot?, now: Date = Date(), calendar: Calendar = .current) async throws -> HealthBriefSnapshot {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        let begin = f.string(from: calendar.date(byAdding: .day, value: -28, to: now)!)
        let records = try await database.asyncRead { db in try GarminStore.records(db: db, since: begin) }
        var facts: [BriefFact] = []
        for (id, metric) in [("sleep", GarminMetric.sleep), ("hrv", .hrv), ("battery", .bodyBattery)] {
            let r = records.first { $0.date == today && $0.metric == metric }
            let observed = r?.payload?.observedAt
            let freshBattery = metric != .bodyBattery || observed.map { now.timeIntervalSince1970 - $0 >= -300 && now.timeIntervalSince1970 - $0 <= 6*3600 } == true
            let current = r?.state == "available" && freshBattery
            let value = current ? r?.payload?.primary : nil
            let note: String
            if value == nil { note = metric == .bodyBattery && r?.payload?.primary != nil ? "观测超过六小时，等待更新" : "等待今日记录" }
            else { note = metric == .bodyBattery ? "最近分段观测，非实时电量" : "按醒来日期归属" }
            facts.append(BriefFact(id: id, title: metric.title, value: value, unit: metric.unit,
                date: today, source: "Garmin Connect · 中国区 Personal API", note: note, observedAt: observed))
        }
        let hrv = records.first { $0.date == today && $0.metric == .hrv && $0.state == "available" }?.payload
        let lower = hrv?.values["balancedLow"], upper = hrv?.values["balancedUpper"]
        let status = hrv?.labels["status"] ?? "NONE"
        let established = lower.map { $0 > 0 } == true && upper.map { $0 >= (lower ?? 0) } == true && HealthBriefRules.validBaselineNotes.contains(status)
        facts.append(BriefFact(id: "hrvBaseline", title: "佳明 HRV 个人基线下界", value: established ? lower : nil,
            unit: "ms", date: today, source: "Garmin Connect", note: established ? status : "NONE"))
        if established, let upper {
            facts.append(BriefFact(id: "hrvBaselineUpper", title: "佳明 HRV 个人基线上界", value: upper, unit: "ms", date: today, source: "Garmin Connect", note: status))
        }
        for (days, label) in [(7,"近七夜"), (28,"近二十八夜")] {
            let key = f.string(from: calendar.date(byAdding: .day, value: -(days-1), to: now)!)
            let values = records.filter { $0.date >= key && $0.date <= today && $0.metric == .hrv && $0.state == "available" }.compactMap { $0.payload?.primary }
            facts.append(BriefFact(id: "hrv\(days)", title: "\(label) HRV 实测均值", value: values.isEmpty ? nil : values.reduce(0,+)/Double(values.count), unit: "ms", date: "\(key) — \(today)", source: "Garmin Connect", note: "有效 \(values.count)/\(days) 夜；描述统计，不替代个人基线"))
        }
        let start = calendar.startOfDay(for: now)
        let chart: [BriefTrainingDay] = (1...7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: start)!
            let day = training?.days.first { $0.key == f.string(from: date) }
            return BriefTrainingDay(date: f.string(from: date), load: day?.recordedLoad,
                minutes: day.map { $0.runMinutes }, incomplete: day == nil || (day?.missingLoadCount ?? 0) > 0 || day?.recordedLoad == nil)
        }
        if let training {
            for (days, id) in [(3,"training72h"),(7,"training7d"),(28,"training28d")] {
                let since = now.addingTimeInterval(-Double(days)*86400)
                let sessions = training.sessions.filter { $0.start >= since && $0.end <= now }
                let loads = sessions.compactMap(\.load)
                facts.append(BriefFact(id: id, title: "近\(days)天已记录训练负荷", value: loads.isEmpty ? nil : loads.reduce(0,+), unit: "AU", date: "\(f.string(from: since)) — \(today)", source: "双源去重训练 · 佳明优先，Apple Watch 校验补全", note: "\(sessions.count)次训练，\(loads.count)次有负荷；缺测不当作休息"))
            }
        }
        let hour = calendar.component(.hour, from: now)
        let phase = hour < 12 ? "morning" : (hour < 18 ? "day" : "evening")
        var result = HealthBriefRules.make(id: "", day: today, phase: phase, facts: facts, training: chart)
        if training == nil { result.limitations.append("训练背景尚在计算，当前解读仅依据持续健康数据。") }
        result.limitations.append("睡眠、HRV 与 Body Battery 相互关联，不作为三项独立证据。")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(result)
        result.id = SHA256.hash(data: bytes + Data(promptVersion.utf8)).map { String(format: "%02x", $0) }.joined()
        return result
    }
}
