import Foundation
import GRDB

/// Daily data-quality reconciliation (PRD R-001).
///
/// For each day in the window, derives three scores from `health_samples_raw`
/// and `source_coverage_daily`, UPSERTs `data_quality_daily`, and emits
/// `missing_data_alerts` rows for metrics below threshold.
///
/// Read-only over raw / coverage tables; writes only to derived tables.
/// Safe to run concurrently with backfill / incremental sync.
final class DailyReconciler {

    struct Config {
        /// 核心指标：缺一个就会触发 alert。
        var coreMetrics: [String] = [
            "HKQuantityTypeIdentifierBodyMass",
            "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierHeartRate",
            "HKCategoryTypeIdentifierSleepAnalysis"
        ]
        /// `completeness_score = core_present / core_total`，低于这个就 warning。
        var completenessWarningThreshold: Double = 0.75
        /// 同一类型同一小时桶有 ≥2 source 就算一次冲突。
        var conflictMinSources: Int = 2
        /// 「最近 N 天连续缺失」升级为 critical。
        var consecutiveMissingForCritical: Int = 3
        /// 默认对账窗口（含今日）。Round 4 调度时按需覆盖。
        var defaultWindowDays: Int = 7
    }

    let database: DatabaseManager
    let config: Config

    init(database: DatabaseManager, config: Config = Config()) {
        self.database = database
        self.config = config
    }

    struct Outcome {
        let datesProcessed: [String]
        let alertsEmitted: Int
        let jobId: Int64
        let startedAt: Date
        let endedAt: Date
        let succeeded: Bool
        let errorMessage: String?
    }

    /// Reconciles the past `windowDays` days ending today (local tz).
    func run(
        windowDays: Int? = nil,
        trigger: SyncJob.Trigger = .timer,
        progress: @escaping (String) -> Void = { _ in }
    ) async throws -> Outcome {

        let start = Date()
        let jobId = try insertJob(trigger: trigger, startedAt: start)

        var firstError: Error?
        var totalAlerts = 0
        var datesProcessed: [String] = []

        let days = windowDays ?? config.defaultWindowDays
        let dates = recentDates(daysBack: days)

        do {
            for (idx, date) in dates.enumerated() {
                progress("[\(idx + 1)/\(dates.count)] 对账 \(date)…")
                let alerts = try reconcileOneDay(date: date, allDatesInWindow: dates)
                totalAlerts += alerts
                datesProcessed.append(date)
            }
        } catch {
            firstError = error
            AppLogger.shared.sync.error("Reconcile failed: \(error.localizedDescription, privacy: .public)")
        }

        let end = Date()
        let succeeded = firstError == nil
        try finaliseJob(
            id: jobId,
            endedAt: end,
            succeeded: succeeded,
            errorMessage: firstError?.localizedDescription,
            stats: ["dates": datesProcessed.count, "alerts": totalAlerts]
        )

        return Outcome(
            datesProcessed: datesProcessed,
            alertsEmitted: totalAlerts,
            jobId: jobId,
            startedAt: start,
            endedAt: end,
            succeeded: succeeded,
            errorMessage: firstError?.localizedDescription
        )
    }

    // MARK: - Per-day reconciliation

    private func reconcileOneDay(date: String, allDatesInWindow: [String]) throws -> Int {
        let (rangeStart, rangeEnd) = epochRange(for: date)

        // 1. Which hk_types have any non-deleted samples that day, and per-type stats.
        struct TypeStat {
            let hkType: String
            let sampleCount: Int
            let lastIngestedAt: Int64
            let distinctSources: Int
            let hourBucketsWithConflict: Int
            let totalHourBuckets: Int
        }

        let typeStats: [TypeStat] = try database.read { db -> [TypeStat] in
            // Per type: sample count, last ingested, distinct source count.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    hk_type,
                    COUNT(*) AS sample_count,
                    MAX(ingested_at) AS last_ingested_at,
                    COUNT(DISTINCT COALESCE(source_bundle_id, 'unknown')) AS distinct_sources
                FROM health_samples_raw
                WHERE is_deleted = 0
                  AND start_at BETWEEN ? AND ?
                GROUP BY hk_type
                """, arguments: [rangeStart, rangeEnd])

            return try rows.map { row in
                let hkType: String = row["hk_type"] ?? ""
                let sampleCount: Int = row["sample_count"] ?? 0
                let lastIngested: Int64 = row["last_ingested_at"] ?? 0
                let distinctSources: Int = row["distinct_sources"] ?? 0

                // Per type, count hour buckets that have ≥2 sources (conflict signal).
                let conflictRows = try Row.fetchAll(db, sql: """
                    SELECT bucket, COUNT(DISTINCT COALESCE(source_bundle_id, 'unknown')) AS srcs
                    FROM (
                        SELECT
                            (start_at / 3600) AS bucket,
                            source_bundle_id
                        FROM health_samples_raw
                        WHERE is_deleted = 0
                          AND hk_type = ?
                          AND start_at BETWEEN ? AND ?
                    )
                    GROUP BY bucket
                    """, arguments: [hkType, rangeStart, rangeEnd])

                let totalBuckets = conflictRows.count
                let conflictBuckets = conflictRows.filter { ($0["srcs"] as Int? ?? 0) >= self.config.conflictMinSources }.count

                return TypeStat(
                    hkType: hkType,
                    sampleCount: sampleCount,
                    lastIngestedAt: lastIngested,
                    distinctSources: distinctSources,
                    hourBucketsWithConflict: conflictBuckets,
                    totalHourBuckets: totalBuckets
                )
            }
        }

        let presentTypes = Set(typeStats.map { $0.hkType })

        // 2. Completeness: fraction of config.coreMetrics present.
        let coreSet = Set(config.coreMetrics)
        let presentCore = coreSet.intersection(presentTypes).count
        let completeness = coreSet.isEmpty ? 1.0 : Double(presentCore) / Double(coreSet.count)

        // 3. Freshness: how recent is the latest sample of any type, vs the end of the day.
        let nowEpoch = Int64(Date().timeIntervalSince1970)
        let latest = typeStats.map { $0.lastIngestedAt }.max() ?? 0
        let ageHours = latest == 0 ? Double.infinity : Double(nowEpoch - latest) / 3600.0
        let freshness: Double = {
            if latest == 0 { return 0.0 }
            if ageHours <= 6 { return 1.0 }
            if ageHours <= 24 { return 0.8 }
            if ageHours <= 72 { return 0.5 }
            if ageHours <= 168 { return 0.25 }
            return 0.0
        }()

        // 4. Conflict: lower = worse. Aggregate across types.
        let totalBuckets = typeStats.reduce(0) { $0 + $1.totalHourBuckets }
        let conflictBuckets = typeStats.reduce(0) { $0 + $1.hourBucketsWithConflict }
        let conflict: Double = totalBuckets == 0
            ? 1.0
            : 1.0 - Double(conflictBuckets) / Double(totalBuckets)

        // 5. Which core metrics are missing?
        let missingCore = coreSet.subtracting(presentTypes).sorted()

        // 6. UPSERT data_quality_daily
        let missingJson = try jsonString(missingCore)
        let computedAt = Int64(Date().timeIntervalSince1970)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO data_quality_daily
                  (date, completeness_score, freshness_score, conflict_score, missing_metrics_json, computed_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET
                  completeness_score = excluded.completeness_score,
                  freshness_score = excluded.freshness_score,
                  conflict_score = excluded.conflict_score,
                  missing_metrics_json = excluded.missing_metrics_json,
                  computed_at = excluded.computed_at
                """, arguments: [date, completeness, freshness, conflict, missingJson, computedAt])
        }

        // 7. Emit alerts for missing core metrics. Severity rises with consecutive missing days.
        var alertsEmitted = 0
        for metric in missingCore {
            let consecutive = try countConsecutiveMissing(metric: metric, upTo: date, dates: allDatesInWindow)
            let severity: MissingDataAlert.Severity = consecutive >= config.consecutiveMissingForCritical
                ? .critical
                : (consecutive >= 1 ? .warning : .info)

            // Skip if same (date, metric) already exists unack'd.
            let exists: Bool = try database.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM missing_data_alerts
                        WHERE date = ? AND metric = ? AND acknowledged = 0
                    )
                    """, arguments: [date, metric]) ?? false
            }
            if exists { continue }

            var alert = MissingDataAlert(
                id: nil,
                date: date,
                metric: metric,
                severity: severity,
                message: "\(date) 缺失 \(humanLabel(for: metric))（连续 \(consecutive) 天）",
                acknowledged: false,
                createdAt: computedAt
            )
            try database.write { db in
                try alert.insert(db)
            }
            alertsEmitted += 1
        }

        // 8. Stale-data alert: if freshness is 0 (no samples in 7+ days), one critical alert.
        if freshness == 0.0, presentTypes.isEmpty {
            let metric = "__stale__"
            let exists: Bool = try database.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM missing_data_alerts
                        WHERE date = ? AND metric = ? AND acknowledged = 0
                    )
                    """, arguments: [date, metric]) ?? false
            }
            if !exists {
                var alert = MissingDataAlert(
                    id: nil,
                    date: date,
                    metric: metric,
                    severity: .critical,
                    message: "\(date) 整日无任何健康样本入库，检查授权或数据源 App。",
                    acknowledged: false,
                    createdAt: computedAt
                )
                try database.write { db in
                    try alert.insert(db)
                }
                alertsEmitted += 1
            }
        }

        AppLogger.shared.sync.info(
            "Reconcile \(date, privacy: .public): completeness=\(completeness), freshness=\(freshness), conflict=\(conflict), alerts=\(alertsEmitted)"
        )
        return alertsEmitted
    }

    // MARK: - Helpers

    /// Returns dates as "yyyy-MM-dd" in local tz, oldest first, including today.
    private func recentDates(daysBack: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<daysBack).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return formatter.string(from: d)
        }
    }

    /// Day boundaries (local tz) for the given "yyyy-MM-dd".
    private func epochRange(for date: String) -> (Int64, Int64) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let dayStart = formatter.date(from: date) else { return (0, 0) }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return (Int64(dayStart.timeIntervalSince1970), Int64(dayEnd.timeIntervalSince1970) - 1)
    }

    private func countConsecutiveMissing(metric: String, upTo date: String, dates: [String]) throws -> Int {
        // Walk back from `date`; stop when we find a day that has the metric.
        guard let idx = dates.firstIndex(of: date) else { return 1 }
        var consecutive = 0
        for i in stride(from: idx, through: 0, by: -1) {
            let d = dates[i]
            let (s, e) = epochRange(for: d)
            let has: Bool = try database.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM health_samples_raw
                        WHERE is_deleted = 0 AND hk_type = ?
                          AND start_at BETWEEN ? AND ?
                    )
                    """, arguments: [metric, s, e]) ?? false
            }
            if has { break }
            consecutive += 1
        }
        return max(1, consecutive)
    }

    private func jsonString(_ array: [String]) throws -> String? {
        let data = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)
    }

    /// Friendly label for an HK identifier. Falls back to the identifier itself.
    static func humanLabel(for hkType: String) -> String {
        switch hkType {
        case "HKQuantityTypeIdentifierBodyMass": return "体重"
        case "HKQuantityTypeIdentifierStepCount": return "步数"
        case "HKQuantityTypeIdentifierHeartRate": return "心率"
        case "HKCategoryTypeIdentifierSleepAnalysis": return "睡眠"
        case "HKQuantityTypeIdentifierBodyFatPercentage": return "体脂率"
        case "HKQuantityTypeIdentifierActiveEnergyBurned": return "活动能量"
        case "HKQuantityTypeIdentifierRestingHeartRate": return "静息心率"
        case "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": return "心率变异性"
        case "HKQuantityTypeIdentifierVO2Max": return "VO₂ Max"
        case "HKWorkoutTypeIdentifier": return "运动"
        case "__stale__": return "全类型停摆"
        default: return hkType
        }
    }

    private func humanLabel(for hkType: String) -> String {
        Self.humanLabel(for: hkType)
    }

    // MARK: - Job lifecycle

    private func insertJob(trigger: SyncJob.Trigger, startedAt: Date) throws -> Int64 {
        var job = SyncJob(
            id: nil,
            jobType: .reconcile,
            state: .running,
            trigger: trigger,
            startedAt: Int64(startedAt.timeIntervalSince1970),
            endedAt: nil,
            errorCode: nil,
            errorMessage: nil,
            statsJson: nil,
            attempt: 1
        )
        try database.write { db in
            try job.insert(db)
        }
        guard let id = job.id else {
            throw NSError(domain: "DailyReconciler", code: -1)
        }
        return id
    }

    private func finaliseJob(
        id: Int64,
        endedAt: Date,
        succeeded: Bool,
        errorMessage: String?,
        stats: [String: Int]
    ) throws {
        let statsData = try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
        let statsJson = String(data: statsData, encoding: .utf8)
        let state = succeeded ? "succeeded" : "failed"

        try database.write { db in
            try db.execute(sql: """
                UPDATE sync_jobs
                SET state = ?, ended_at = ?, error_message = ?, stats_json = ?
                WHERE id = ?
                """, arguments: [
                    state,
                    Int64(endedAt.timeIntervalSince1970),
                    errorMessage,
                    statsJson,
                    id
                ])
        }
    }
}
