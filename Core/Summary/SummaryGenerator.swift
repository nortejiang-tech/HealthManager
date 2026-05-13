import Foundation
import GRDB

/// Deterministic daily/weekly summary generator (PRD §F-006).
///
/// V1 is text-template + numeric aggregation, not LLM. Future rounds can swap in an LLM
/// behind the same `Generated` struct without touching UI.
final class SummaryGenerator {

    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    struct Generated {
        let text: String
        let findings: [String: AnyHashable]
        let qualityScore: Double?
    }

    // MARK: - Daily

    @discardableResult
    func generateDaily(for date: String = todayKey()) throws -> DailySummary {
        let report = try buildDailyReport(for: date)
        let findingsJson = try jsonString(report.findings)
        let summary = DailySummary(
            date: date,
            summaryText: report.text,
            keyFindingsJson: findingsJson,
            qualityScore: report.qualityScore,
            generatedAt: Int64(Date().timeIntervalSince1970)
        )
        try database.write { db in
            try summary.insert(db, onConflict: .replace)
        }
        return summary
    }

    private func buildDailyReport(for date: String) throws -> Generated {
        let (dayStart, dayEnd) = epochRange(for: date)

        let stats: DailyStats = try database.read { db in
            // Per-type sample counts
            let countsRows = try Row.fetchAll(db, sql: """
                SELECT hk_type, COUNT(*) AS c, AVG(value) AS avg_v, SUM(value) AS sum_v
                FROM health_samples_raw
                WHERE is_deleted = 0 AND start_at BETWEEN ? AND ?
                GROUP BY hk_type
                """, arguments: [dayStart, dayEnd])
            var perType: [String: (count: Int, avg: Double, sum: Double)] = [:]
            for r in countsRows {
                let t: String = r["hk_type"] ?? ""
                perType[t] = (r["c"] ?? 0, r["avg_v"] ?? 0, r["sum_v"] ?? 0)
            }

            let mealRow = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS c,
                    COALESCE(SUM(calories_kcal), 0) AS cal,
                    COALESCE(SUM(protein_g), 0) AS pro
                FROM meal_records
                WHERE eaten_at BETWEEN ? AND ?
                """, arguments: [dayStart, dayEnd])
            let mealCount: Int = mealRow?["c"] ?? 0
            let caloriesIn: Double = mealRow?["cal"] ?? 0
            let proteinIn: Double = mealRow?["pro"] ?? 0

            let medCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_logs
                WHERE action = 'taken' AND COALESCE(action_at, scheduled_at) BETWEEN ? AND ?
                """, arguments: [dayStart, dayEnd]) ?? 0

            let quality = try DataQualityDaily.fetchOne(db, key: date)

            return DailyStats(
                perType: perType,
                mealCount: mealCount,
                caloriesIn: caloriesIn,
                proteinIn: proteinIn,
                medTakenCount: medCount,
                quality: quality
            )
        }

        return renderDaily(date: date, stats: stats)
    }

    private struct DailyStats {
        let perType: [String: (count: Int, avg: Double, sum: Double)]
        let mealCount: Int
        let caloriesIn: Double
        let proteinIn: Double
        let medTakenCount: Int
        let quality: DataQualityDaily?
    }

    private func renderDaily(date: String, stats: DailyStats) -> Generated {
        var lines: [String] = []
        var findings: [String: AnyHashable] = [:]

        lines.append("【\(date) 日报】")

        if let steps = stats.perType["HKQuantityTypeIdentifierStepCount"]?.sum {
            lines.append("• 步数：\(Int(steps)) 步")
            findings["steps"] = Int(steps)
        }
        if let energy = stats.perType["HKQuantityTypeIdentifierActiveEnergyBurned"]?.sum {
            lines.append(String(format: "• 活动能量：%.0f kcal", energy))
            findings["activeEnergyKcal"] = Int(energy)
        }
        if let hr = stats.perType["HKQuantityTypeIdentifierHeartRate"]?.avg {
            lines.append(String(format: "• 平均心率：%.0f bpm", hr))
            findings["avgHR"] = Int(hr)
        }
        if let resting = stats.perType["HKQuantityTypeIdentifierRestingHeartRate"]?.avg {
            lines.append(String(format: "• 静息心率：%.0f bpm", resting))
            findings["restingHR"] = Int(resting)
        }
        if let weight = stats.perType["HKQuantityTypeIdentifierBodyMass"]?.avg {
            lines.append(String(format: "• 体重：%.2f kg", weight))
            findings["weightKg"] = weight
        }

        if stats.mealCount > 0 {
            lines.append(String(format: "• 饮食：%d 餐 / 摄入 %.0f kcal / 蛋白 %.0f g",
                                stats.mealCount, stats.caloriesIn, stats.proteinIn))
            findings["mealCount"] = stats.mealCount
            findings["caloriesIn"] = Int(stats.caloriesIn)
        }
        if stats.medTakenCount > 0 {
            lines.append("• 用药：当日服用 \(stats.medTakenCount) 次")
            findings["medTakenCount"] = stats.medTakenCount
        }

        if let q = stats.quality {
            if let c = q.completenessScore {
                lines.append(String(format: "• 数据完整度 %.0f%%", c * 100))
                findings["completeness"] = c
            }
            if let missingJson = q.missingMetricsJson,
               let missing = decodeStringArray(missingJson), !missing.isEmpty {
                lines.append("• 缺失：" + missing.map(DailyReconciler.humanLabel(for:)).joined(separator: "、"))
                findings["missing"] = missing
            }
        }

        if lines.count == 1 {
            lines.append("• 当日无可汇总数据。")
        }

        let qScore: Double? = stats.quality?.completenessScore
        return Generated(text: lines.joined(separator: "\n"), findings: findings, qualityScore: qScore)
    }

    // MARK: - Weekly

    @discardableResult
    func generateWeekly(weekStart: String = currentWeekStartKey()) throws -> WeeklySummary {
        let report = try buildWeeklyReport(weekStart: weekStart)
        let findingsJson = try jsonString(report.findings)
        let summary = WeeklySummary(
            weekStartDate: weekStart,
            summaryText: report.text,
            findingsJson: findingsJson,
            qualityScore: report.qualityScore,
            generatedAt: Int64(Date().timeIntervalSince1970)
        )
        try database.write { db in
            try summary.insert(db, onConflict: .replace)
        }
        return summary
    }

    private func buildWeeklyReport(weekStart: String) throws -> Generated {
        guard let (s, e) = weekRange(weekStart: weekStart) else {
            return Generated(text: "无效的周起始日期。", findings: [:], qualityScore: nil)
        }

        struct Agg {
            var stepsTotal: Double = 0
            var energyTotal: Double = 0
            var avgHR: Double = 0
            var hrSamples: Int = 0
            var minWeight: Double = .infinity
            var maxWeight: Double = -.infinity
            var weightSamples: Int = 0
            var mealCount: Int = 0
            var caloriesIn: Double = 0
            var medTaken: Int = 0
            var avgCompleteness: Double = 0
            var completenessDays: Int = 0
        }

        let agg: Agg = try database.read { db in
            var a = Agg()
            let rows = try Row.fetchAll(db, sql: """
                SELECT hk_type, value FROM health_samples_raw
                WHERE is_deleted = 0 AND start_at BETWEEN ? AND ?
                """, arguments: [s, e])
            for r in rows {
                let t: String = r["hk_type"] ?? ""
                let v: Double = r["value"] ?? 0
                switch t {
                case "HKQuantityTypeIdentifierStepCount":
                    a.stepsTotal += v
                case "HKQuantityTypeIdentifierActiveEnergyBurned":
                    a.energyTotal += v
                case "HKQuantityTypeIdentifierHeartRate":
                    a.avgHR += v
                    a.hrSamples += 1
                case "HKQuantityTypeIdentifierBodyMass":
                    a.minWeight = min(a.minWeight, v)
                    a.maxWeight = max(a.maxWeight, v)
                    a.weightSamples += 1
                default:
                    break
                }
            }

            let mealRow = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(SUM(calories_kcal), 0) AS cal
                FROM meal_records WHERE eaten_at BETWEEN ? AND ?
                """, arguments: [s, e])
            a.mealCount = mealRow?["c"] ?? 0
            a.caloriesIn = mealRow?["cal"] ?? 0

            a.medTaken = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_logs
                WHERE action = 'taken' AND COALESCE(action_at, scheduled_at) BETWEEN ? AND ?
                """, arguments: [s, e]) ?? 0

            let cRows = try Row.fetchAll(db, sql: """
                SELECT completeness_score FROM data_quality_daily WHERE date >= ?
                LIMIT 7
                """, arguments: [weekStart])
            for r in cRows {
                if let v: Double = r["completeness_score"] {
                    a.avgCompleteness += v
                    a.completenessDays += 1
                }
            }

            return a
        }

        var lines: [String] = []
        var findings: [String: AnyHashable] = [:]

        lines.append("【\(weekStart) 起的一周】")
        lines.append("• 步数累计：\(Int(agg.stepsTotal)) 步（日均 \(Int(agg.stepsTotal / 7))）")
        findings["stepsTotal"] = Int(agg.stepsTotal)
        lines.append(String(format: "• 活动能量累计：%.0f kcal", agg.energyTotal))
        findings["activeEnergyTotalKcal"] = Int(agg.energyTotal)

        if agg.hrSamples > 0 {
            let avg = agg.avgHR / Double(agg.hrSamples)
            lines.append(String(format: "• 平均心率：%.0f bpm", avg))
            findings["avgHR"] = Int(avg)
        }
        if agg.weightSamples > 0, agg.minWeight.isFinite {
            lines.append(String(format: "• 体重区间：%.2f – %.2f kg", agg.minWeight, agg.maxWeight))
            findings["weightMin"] = agg.minWeight
            findings["weightMax"] = agg.maxWeight
        }
        if agg.mealCount > 0 {
            lines.append(String(format: "• 饮食：%d 餐 / 摄入 %.0f kcal", agg.mealCount, agg.caloriesIn))
        }
        if agg.medTaken > 0 {
            lines.append("• 用药：服用 \(agg.medTaken) 次")
            findings["medTakenCount"] = agg.medTaken
        }

        let qScore: Double?
        if agg.completenessDays > 0 {
            let avgC = agg.avgCompleteness / Double(agg.completenessDays)
            lines.append(String(format: "• 数据平均完整度 %.0f%%（%d 天有对账）", avgC * 100, agg.completenessDays))
            qScore = avgC
        } else {
            qScore = nil
        }

        return Generated(text: lines.joined(separator: "\n"), findings: findings, qualityScore: qScore)
    }

    // MARK: - Helpers

    private func jsonString(_ dict: [String: AnyHashable]) throws -> String? {
        let data = try JSONSerialization.data(withJSONObject: dict.mapValues { $0 as Any }, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)
    }

    private func decodeStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String]
    }

    private func epochRange(for date: String) -> (Int64, Int64) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let day = f.date(from: date) else { return (0, 0) }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return (Int64(day.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
    }

    private func weekRange(weekStart: String) -> (Int64, Int64)? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let start = f.date(from: weekStart) else { return nil }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        return (Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970) - 1)
    }

    static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func currentWeekStartKey() -> String {
        let calendar = Calendar(identifier: .iso8601)
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        // ISO: weekday 2 = Monday. Compute offset to Monday.
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: monday)
    }
}
