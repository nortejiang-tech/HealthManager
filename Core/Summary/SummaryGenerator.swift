import Foundation
import GRDB

/// Deterministic daily/weekly summary generator (PRD §F-006).
///
/// V1 is text-template + numeric aggregation, not LLM. Future rounds can swap in an LLM
/// behind the same `Generated` struct without touching UI.
///
/// Marked `actor` so synchronous GRDB reads inside `generateDaily` / `generateWeekly`
/// run on the actor's executor and don't block the caller's actor (e.g. MainActor).
actor SummaryGenerator {

    static let nutritionEvidenceContractKey = "nutritionEvidenceContractVersion"
    static let nutritionEvidenceContractVersion = 1

    let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    struct Generated {
        let text: String
        let findings: [String: AnyHashable]
        let qualityScore: Double?
    }

    /// Cumulative quantity types where the same minute can be written by multiple sources
    /// (iPhone CoreMotion + Apple Watch + Garmin + 米家 …). SUM(value) across sources
    /// double-counts. For these we pick a *dominant source per day* and use only its samples.
    private static let cumulativeTypes: Set<String> = [
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierAppleStandTime",
    ]

    /// Dominant-source sum for one cumulative type in [start, end].
    private func cumulativeSum(db: Database, hkType: String, start: Int64, end: Int64) throws -> Double {
        try ActivityEnergyCalculator.cumulativeSum(db: db, hkType: hkType, start: start, end: end)
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

    /// Loads an already-generated daily summary. Legacy rows are rebuilt against the
    /// current evidence contract, but a missing row stays missing so passive reads do
    /// not acquire a hidden write side effect.
    func currentDaily(for date: String = todayKey()) throws -> DailySummary? {
        guard let existing = try database.read({ db in
            try DailySummary.fetchOne(db, key: date)
        }) else {
            return nil
        }
        if Self.hasCurrentNutritionContract(existing.keyFindingsJson) {
            return existing
        }
        return try generateDaily(for: date)
    }

    /// Rebuilds and persists the deterministic daily summary used as LLM input. This
    /// intentionally invalidates any previously stored LLM commentary before networking.
    func rebuildDailyForLLM(for date: String) throws -> String? {
        try generateDaily(for: date).summaryText
    }

    private func buildDailyReport(for date: String) throws -> Generated {
        let (dayStart, dayEnd) = epochRange(for: date)

        let stats: DailyStats = try database.read { db in
            // Per-type sample counts. SUM is still computed here for non-cumulative types
            // (kept for findings completeness), but cumulative types are recomputed below
            // via cumulativeSum to avoid cross-source double counting.
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

            // Dominant-source dedup for the cumulative metrics shown in the report.
            // nil = no samples at all that day → render layer skips the line.
            let stepsDedup = perType["HKQuantityTypeIdentifierStepCount"] == nil
                ? nil
                : try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierStepCount", start: dayStart, end: dayEnd)
            let activeEnergy = try ActivityEnergyCalculator.dailyActiveEnergyKcal(
                db: db,
                start: dayStart,
                end: dayEnd
            )
            let activeEnergyDedup = activeEnergy > 0 ? activeEnergy : nil

            let localDay = Date(timeIntervalSince1970: TimeInterval(dayStart))
            let mealNutrition = try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: localDay,
                throughLocalDay: localDay,
                calendar: .current
            )

            let medCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM medication_logs
                WHERE action = 'taken' AND COALESCE(action_at, scheduled_at) BETWEEN ? AND ?
                """, arguments: [dayStart, dayEnd]) ?? 0

            let quality = try DataQualityDaily.fetchOne(db, key: date)

            return DailyStats(
                perType: perType,
                stepsDedup: stepsDedup,
                activeEnergyDedup: activeEnergyDedup,
                mealNutrition: mealNutrition,
                medTakenCount: medCount,
                quality: quality
            )
        }

        return renderDaily(date: date, stats: stats)
    }

    private struct DailyStats {
        let perType: [String: (count: Int, avg: Double, sum: Double)]
        let stepsDedup: Double?
        let activeEnergyDedup: Double?
        let mealNutrition: MealNutritionEvidenceWindow
        let medTakenCount: Int
        let quality: DataQualityDaily?
    }

    private func renderDaily(date: String, stats: DailyStats) -> Generated {
        var lines: [String] = []
        var findings: [String: AnyHashable] = [
            Self.nutritionEvidenceContractKey: Self.nutritionEvidenceContractVersion
        ]

        lines.append("【\(date) 日报】")

        if let steps = stats.stepsDedup {
            lines.append("• 步数：\(Int(steps)) 步")
            findings["steps"] = Int(steps)
        }
        if let energy = stats.activeEnergyDedup {
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

        if stats.mealNutrition.mealCount > 0 {
            var parts = ["\(stats.mealNutrition.mealCount) 餐"]
            if let calories = stats.mealNutrition.totals?.caloriesKcal {
                parts.append(String(format: "摄入 %.0f kcal", calories))
                findings["caloriesIn"] = calories
            } else {
                parts.append("热量记录不完整")
                findings["caloriesInStatus"] = "incomplete"
            }
            if let protein = stats.mealNutrition.totals?.proteinG {
                parts.append(String(format: "蛋白 %.0f g", protein))
                findings["proteinIn"] = protein
            } else {
                parts.append("蛋白质记录不完整")
                findings["proteinInStatus"] = "incomplete"
            }
            lines.append("• 饮食：" + parts.joined(separator: " / "))
            findings["mealCount"] = stats.mealNutrition.mealCount
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

    /// Weekly counterpart to `currentDaily`: validates persisted rows without creating
    /// a report merely because the summary screen was opened or refreshed.
    func currentWeekly(weekStart: String = currentWeekStartKey()) throws -> WeeklySummary? {
        guard let existing = try database.read({ db in
            try WeeklySummary.fetchOne(db, key: weekStart)
        }) else {
            return nil
        }
        if Self.hasCurrentNutritionContract(existing.findingsJson) {
            return existing
        }
        return try generateWeekly(weekStart: weekStart)
    }

    /// Weekly counterpart to `rebuildDailyForLLM`; it writes the fresh deterministic
    /// summary and clears previously persisted LLM commentary.
    func rebuildWeeklyForLLM(weekStart: String) throws -> String? {
        try generateWeekly(weekStart: weekStart).summaryText
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
            var mealNutrition: MealNutritionEvidenceWindow = .empty
            var medTaken: Int = 0
            var avgCompleteness: Double = 0
            var completenessDays: Int = 0
        }

        // Each day picks its own dominant source independently — Garmin may have synced
        // day 1 but not day 2, and we want the best available source per day.
        let weekDayKeys: [String] = (0..<7).compactMap { offset in
            let cal = Calendar.current
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let weekStartDate = f.date(from: weekStart),
                  let d = cal.date(byAdding: .day, value: offset, to: weekStartDate)
            else { return nil }
            return f.string(from: d)
        }

        let agg: Agg = try database.read { db in
            var a = Agg()

            // Cumulative metrics: per-day dominant-source dedup, then sum across the week.
            for dayKey in weekDayKeys {
                let (dayStart, dayEnd) = epochRange(for: dayKey)
                a.stepsTotal += try cumulativeSum(
                    db: db, hkType: "HKQuantityTypeIdentifierStepCount",
                    start: dayStart, end: dayEnd
                )
                a.energyTotal += try ActivityEnergyCalculator.dailyActiveEnergyKcal(
                    db: db,
                    start: dayStart,
                    end: dayEnd
                )
            }

            // Non-cumulative (HR / weight) are unaffected by multi-source duplication —
            // keep the simple window scan.
            let rows = try Row.fetchAll(db, sql: """
                SELECT hk_type, value FROM health_samples_raw
                WHERE is_deleted = 0 AND start_at BETWEEN ? AND ?
                  AND hk_type IN ('HKQuantityTypeIdentifierHeartRate', 'HKQuantityTypeIdentifierBodyMass')
                """, arguments: [s, e])
            for r in rows {
                let t: String = r["hk_type"] ?? ""
                let v: Double = r["value"] ?? 0
                switch t {
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

            let startDay = Date(timeIntervalSince1970: TimeInterval(s))
            let finalDay = Calendar.current.date(byAdding: .day, value: 6, to: startDay) ?? startDay
            a.mealNutrition = try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: startDay,
                throughLocalDay: finalDay,
                calendar: .current
            )

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
        var findings: [String: AnyHashable] = [
            Self.nutritionEvidenceContractKey: Self.nutritionEvidenceContractVersion
        ]

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
        if agg.mealNutrition.mealCount > 0 {
            var parts = ["\(agg.mealNutrition.mealCount) 餐"]
            if let calories = agg.mealNutrition.totals?.caloriesKcal {
                parts.append(String(format: "摄入 %.0f kcal", calories))
                findings["caloriesIn"] = calories
            } else {
                parts.append("热量记录不完整")
                findings["caloriesInStatus"] = "incomplete"
            }
            lines.append("• 饮食：" + parts.joined(separator: " / "))
            findings["mealCount"] = agg.mealNutrition.mealCount
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

    // MARK: - LLM augmentation

    /// Calls the configured LLM with the deterministic summary text as user content,
    /// writes the response back into `daily_summaries.llm_text` (and model/timestamp).
    /// Returns the LLM commentary or throws.
    /// The deterministic summary is always rebuilt and persisted first. If LLM access is
    /// disabled or unavailable, returns nil after that local invalidation without a request.
    @discardableResult
    func augmentDailyWithLLM(for date: String) async throws -> String? {
        // Rebuild locally first so stale deterministic text or LLM commentary can never
        // survive an augmentation attempt, even when networking is disabled/unavailable.
        let baseText = try rebuildDailyForLLM(for: date)
        guard let baseText, !baseText.isEmpty else { return nil }
        guard LLMConfig.enabled, let client = LLMClient(fromConfig: true) else { return nil }

        let commentary = try await client.complete(
            systemPrompt: LLMClient.summarySystemPrompt,
            user: baseText
        )
        let now = Int64(Date().timeIntervalSince1970)
        let model = client.model
        try database.write { db in
            try db.execute(sql: """
                UPDATE daily_summaries
                SET llm_text = ?, llm_model = ?, llm_generated_at = ?
                WHERE date = ?
                """, arguments: [commentary, model, now, date])
        }
        return commentary
    }

    /// Same as `augmentDailyWithLLM` but for the weekly summary.
    @discardableResult
    func augmentWeeklyWithLLM(weekStart: String) async throws -> String? {
        let baseText = try rebuildWeeklyForLLM(weekStart: weekStart)
        guard let baseText, !baseText.isEmpty else { return nil }
        guard LLMConfig.enabled, let client = LLMClient(fromConfig: true) else { return nil }

        let commentary = try await client.complete(
            systemPrompt: LLMClient.summarySystemPrompt,
            user: baseText
        )
        let now = Int64(Date().timeIntervalSince1970)
        let model = client.model
        try database.write { db in
            try db.execute(sql: """
                UPDATE weekly_summaries
                SET llm_text = ?, llm_model = ?, llm_generated_at = ?
                WHERE week_start_date = ?
                """, arguments: [commentary, model, now, weekStart])
        }
        return commentary
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

    private static func hasCurrentNutritionContract(_ json: String?) -> Bool {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object[nutritionEvidenceContractKey] as? NSNumber
        else {
            return false
        }
        return version.intValue == nutritionEvidenceContractVersion
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
