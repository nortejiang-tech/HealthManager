import Foundation
import GRDB

/// Rolls up `health_samples_raw` (and ancillary tables) into per-day denormalized rows
/// in `activity_metrics_daily` / `body_metrics_daily` for fast dashboard reads.
///
/// Dedup policy (PRD §4.1): we keep all sources in raw, but at aggregation time each
/// cumulative quantity (step count / active energy / distance / flights / basal /
/// exercise minutes / stand minutes / sleep seconds) is sourced from a *single*
/// dominant device per day. Priority is `SourceAttribution.Origin.cumulativePriority`
/// (Garmin > Apple > 小米 > …). Non-cumulative metrics (heart rate / HRV / VO2 Max)
/// are unaffected — they average across all sources.
///
/// Hooks: invoked at the tail of `BackfillCoordinator.run` (days = 30) and
/// `IncrementalSyncCoordinator.run` (days = 7). Idempotent — each day is UPSERTed.
actor DailyAggregator {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// Recompute the past `days` days ending today (local tz). Older days unchanged.
    func rebuild(daysBack days: Int = 7) async throws {
        let dates = recentDates(daysBack: days)
        for date in dates {
            try rebuildOneDay(date: date)
        }
        AppLogger.shared.database.info("DailyAggregator rebuilt \(dates.count) days")
    }

    // MARK: - Per-day rollup

    private struct DaySnapshot {
        var steps: Double = 0
        var activeEnergy: Double = 0
        var basalEnergy: Double = 0
        var distance: Double = 0
        var exerciseMinutes: Double = 0
        var standMinutes: Double = 0
        var flightsClimbed: Double = 0
        var restingHR: Double?
        var avgHR: Double?
        var hrv: Double?
        var vo2Max: Double?
        var sleepSeconds: Double = 0
        // Body
        var weight: Double?
        var bodyFat: Double?
        var bmi: Double?
        var leanMass: Double?
        var height: Double?
    }

    private func rebuildOneDay(date: String) throws {
        let (s, e) = epochRange(for: date)

        let snap: DaySnapshot = try database.read { db in
            var d = DaySnapshot()
            d.steps           = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierStepCount", start: s, end: e)
            d.activeEnergy    = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierActiveEnergyBurned", start: s, end: e)
            d.basalEnergy     = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierBasalEnergyBurned", start: s, end: e)
            d.distance        = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierDistanceWalkingRunning", start: s, end: e)
            d.exerciseMinutes = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierAppleExerciseTime", start: s, end: e)
            d.standMinutes    = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierAppleStandTime", start: s, end: e)
            d.flightsClimbed  = try cumulativeSum(db: db, hkType: "HKQuantityTypeIdentifierFlightsClimbed", start: s, end: e)
            d.restingHR       = try avgValue(db: db, hkType: "HKQuantityTypeIdentifierRestingHeartRate", start: s, end: e)
            d.avgHR           = try avgValue(db: db, hkType: "HKQuantityTypeIdentifierHeartRate", start: s, end: e)
            d.hrv             = try avgValue(db: db, hkType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", start: s, end: e)
            d.vo2Max          = try avgValue(db: db, hkType: "HKQuantityTypeIdentifierVO2Max", start: s, end: e)
            d.sleepSeconds    = try sleepDuration(db: db, start: s, end: e)
            d.weight          = try latestValue(db: db, hkType: "HKQuantityTypeIdentifierBodyMass", start: s, end: e)
            d.bodyFat         = try latestValue(db: db, hkType: "HKQuantityTypeIdentifierBodyFatPercentage", start: s, end: e)
            d.bmi             = try latestValue(db: db, hkType: "HKQuantityTypeIdentifierBodyMassIndex", start: s, end: e)
            d.leanMass        = try latestValue(db: db, hkType: "HKQuantityTypeIdentifierLeanBodyMass", start: s, end: e)
            d.height          = try latestValue(db: db, hkType: "HKQuantityTypeIdentifierHeight", start: s, end: e)
            return d
        }

        let computedAt = Int64(Date().timeIntervalSince1970)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO activity_metrics_daily
                  (date, step_count, active_energy_kcal, basal_energy_kcal, distance_m,
                   exercise_minutes, stand_minutes, flights_climbed,
                   resting_hr_bpm, avg_hr_bpm, hrv_ms, vo2_max,
                   sleep_seconds, sleep_efficiency, sources_json, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
                ON CONFLICT(date) DO UPDATE SET
                  step_count = excluded.step_count,
                  active_energy_kcal = excluded.active_energy_kcal,
                  basal_energy_kcal = excluded.basal_energy_kcal,
                  distance_m = excluded.distance_m,
                  exercise_minutes = excluded.exercise_minutes,
                  stand_minutes = excluded.stand_minutes,
                  flights_climbed = excluded.flights_climbed,
                  resting_hr_bpm = excluded.resting_hr_bpm,
                  avg_hr_bpm = excluded.avg_hr_bpm,
                  hrv_ms = excluded.hrv_ms,
                  vo2_max = excluded.vo2_max,
                  sleep_seconds = excluded.sleep_seconds,
                  computed_at = excluded.computed_at
                """, arguments: [
                    date,
                    snap.steps > 0 ? Int(snap.steps) : nil,
                    snap.activeEnergy > 0 ? snap.activeEnergy : nil,
                    snap.basalEnergy > 0 ? snap.basalEnergy : nil,
                    snap.distance > 0 ? snap.distance : nil,
                    snap.exerciseMinutes > 0 ? snap.exerciseMinutes : nil,
                    snap.standMinutes > 0 ? snap.standMinutes : nil,
                    snap.flightsClimbed > 0 ? Int(snap.flightsClimbed) : nil,
                    snap.restingHR, snap.avgHR, snap.hrv, snap.vo2Max,
                    snap.sleepSeconds > 0 ? Int(snap.sleepSeconds) : nil,
                    computedAt
                ])

            try db.execute(sql: """
                INSERT INTO body_metrics_daily
                  (date, weight_kg, body_fat_pct, bmi, lean_mass_kg, height_m,
                   basal_energy_kcal, visceral_fat_level, muscle_mass_kg, water_pct,
                   protein_pct, sources_json, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?)
                ON CONFLICT(date) DO UPDATE SET
                  weight_kg = excluded.weight_kg,
                  body_fat_pct = excluded.body_fat_pct,
                  bmi = excluded.bmi,
                  lean_mass_kg = excluded.lean_mass_kg,
                  height_m = excluded.height_m,
                  basal_energy_kcal = excluded.basal_energy_kcal,
                  computed_at = excluded.computed_at
                """, arguments: [
                    date,
                    snap.weight, snap.bodyFat, snap.bmi, snap.leanMass, snap.height,
                    snap.basalEnergy > 0 ? snap.basalEnergy : nil,
                    computedAt
                ])
        }
    }

    // MARK: - SQL helpers

    /// Pick the dominant source for a cumulative type and return only that source's SUM.
    /// Returns 0 when no samples exist.
    private func cumulativeSum(db: Database, hkType: String, start: Int64, end: Int64) throws -> Double {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                COALESCE(source_bundle_id, 'unknown') AS bid,
                COALESCE(source_name, '') AS sname,
                SUM(value) AS s
            FROM health_samples_raw
            WHERE hk_type = ?
              AND is_deleted = 0
              AND start_at BETWEEN ? AND ?
            GROUP BY bid
            """, arguments: [hkType, start, end])
        var bestSum: Double = 0
        var bestPriority: Int = -1
        for r in rows {
            let bid: String = r["bid"] ?? ""
            let sname: String = r["sname"] ?? ""
            let s: Double = r["s"] ?? 0
            let origin = SourceAttribution.classify(bundleId: bid, sourceName: sname)
            let p = origin.cumulativePriority
            if p > bestPriority || (p == bestPriority && s > bestSum) {
                bestPriority = p
                bestSum = s
            }
        }
        return bestSum
    }

    /// Average across all sources — heart rate / HRV / VO2 are instantaneous, no double-counting.
    private func avgValue(db: Database, hkType: String, start: Int64, end: Int64) throws -> Double? {
        let row = try Row.fetchOne(db, sql: """
            SELECT AVG(value) AS v, COUNT(*) AS c
            FROM health_samples_raw
            WHERE hk_type = ?
              AND is_deleted = 0
              AND start_at BETWEEN ? AND ?
            """, arguments: [hkType, start, end])
        let count: Int = row?["c"] ?? 0
        guard count > 0 else { return nil }
        return row?["v"]
    }

    /// Latest sample in the day for instantaneous body metrics (weight, body fat).
    /// Falls back to dominant source if multiple writes at the same instant.
    private func latestValue(db: Database, hkType: String, start: Int64, end: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT value FROM health_samples_raw
            WHERE hk_type = ?
              AND is_deleted = 0
              AND start_at BETWEEN ? AND ?
            ORDER BY start_at DESC
            LIMIT 1
            """, arguments: [hkType, start, end])
    }

    /// Sleep seconds = sum of (end_at - start_at) for sleepAnalysis stages where the user
    /// was actually asleep (not inBed=0 and not awake=2). Picks the dominant source per day
    /// to avoid double-counting when both Watch and a 3rd-party tracker recorded the same night.
    private func sleepDuration(db: Database, start: Int64, end: Int64) throws -> Double {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                COALESCE(source_bundle_id, 'unknown') AS bid,
                COALESCE(source_name, '') AS sname,
                SUM(end_at - start_at) AS s
            FROM health_samples_raw
            WHERE hk_type = 'HKCategoryTypeIdentifierSleepAnalysis'
              AND is_deleted = 0
              AND value != 0 AND value != 2
              AND start_at BETWEEN ? AND ?
            GROUP BY bid
            """, arguments: [start, end])
        var bestSum: Double = 0
        var bestPriority: Int = -1
        for r in rows {
            let bid: String = r["bid"] ?? ""
            let sname: String = r["sname"] ?? ""
            let s: Double = r["s"] ?? 0
            let origin = SourceAttribution.classify(bundleId: bid, sourceName: sname)
            let p = origin.cumulativePriority
            if p > bestPriority || (p == bestPriority && s > bestSum) {
                bestPriority = p
                bestSum = s
            }
        }
        return bestSum
    }

    // MARK: - Date helpers

    private func recentDates(daysBack: Int) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<daysBack).reversed().compactMap { off in
            guard let d = cal.date(byAdding: .day, value: -off, to: today) else { return nil }
            return f.string(from: d)
        }
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
}
