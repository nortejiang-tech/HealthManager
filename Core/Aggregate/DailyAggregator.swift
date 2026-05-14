import Foundation
import GRDB

/// Rolls up `health_samples_raw` into the per-day projection tables
/// (`body_metrics_daily`, `activity_metrics_daily`) consumed by the dashboard.
///
/// Triggered at the end of every sync (backfill / incremental / manual).
/// Idempotent: re-running the same window UPSERTs by `date` PK.
actor DailyAggregator {

    nonisolated let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - HK identifier shortcuts
    private enum HK {
        static let bodyMass = "HKQuantityTypeIdentifierBodyMass"
        static let bodyFat = "HKQuantityTypeIdentifierBodyFatPercentage"
        static let bmi = "HKQuantityTypeIdentifierBodyMassIndex"
        static let leanMass = "HKQuantityTypeIdentifierLeanBodyMass"
        static let basalEnergy = "HKQuantityTypeIdentifierBasalEnergyBurned"
        static let height = "HKQuantityTypeIdentifierHeight"

        static let stepCount = "HKQuantityTypeIdentifierStepCount"
        static let activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
        static let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
        static let exerciseTime = "HKQuantityTypeIdentifierAppleExerciseTime"
        static let standTime = "HKQuantityTypeIdentifierAppleStandTime"
        static let flights = "HKQuantityTypeIdentifierFlightsClimbed"

        static let heartRate = "HKQuantityTypeIdentifierHeartRate"
        static let restingHR = "HKQuantityTypeIdentifierRestingHeartRate"
        static let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        static let vo2Max = "HKQuantityTypeIdentifierVO2Max"

        static let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    }

    /// Aggregate the most recent `windowDays` (default 90; backfill calls with 30+).
    @discardableResult
    func run(windowDays: Int = 90) async throws -> Int {
        let dates = recentDates(daysBack: windowDays)
        for date in dates {
            try aggregateOneDay(date: date)
        }
        AppLogger.shared.sync.info("DailyAggregator: rolled up \(dates.count) days")
        return dates.count
    }

    // MARK: - Per-day rollup

    private func aggregateOneDay(date: String) throws {
        let (rangeStart, rangeEnd) = epochRange(for: date)
        let computedAt = Int64(Date().timeIntervalSince1970)

        try database.write { db in
            // ---- body_metrics_daily ----
            let weight = try latestValue(db, hkType: HK.bodyMass, start: rangeStart, end: rangeEnd)
            let bodyFat = try latestValue(db, hkType: HK.bodyFat, start: rangeStart, end: rangeEnd)
            let bmi = try latestValue(db, hkType: HK.bmi, start: rangeStart, end: rangeEnd)
            let leanMass = try latestValue(db, hkType: HK.leanMass, start: rangeStart, end: rangeEnd)
            let height = try latestValue(db, hkType: HK.height, start: rangeStart, end: rangeEnd)
            let basalEnergy = try sumValue(db, hkType: HK.basalEnergy, start: rangeStart, end: rangeEnd)

            // Only write a body row if at least one signal is present (avoid empty rows polluting charts).
            let bodyHasAny = [weight, bodyFat, bmi, leanMass, height, basalEnergy].contains { $0 != nil }
            if bodyHasAny {
                try db.execute(sql: """
                    INSERT INTO body_metrics_daily
                      (date, weight_kg, body_fat_pct, bmi, lean_mass_kg, height_m, basal_energy_kcal, computed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(date) DO UPDATE SET
                      weight_kg = excluded.weight_kg,
                      body_fat_pct = excluded.body_fat_pct,
                      bmi = excluded.bmi,
                      lean_mass_kg = excluded.lean_mass_kg,
                      height_m = excluded.height_m,
                      basal_energy_kcal = excluded.basal_energy_kcal,
                      computed_at = excluded.computed_at
                    """, arguments: [date, weight, bodyFat, bmi, leanMass, height, basalEnergy, computedAt])
            }

            // ---- activity_metrics_daily ----
            let stepsDouble = try sumValue(db, hkType: HK.stepCount, start: rangeStart, end: rangeEnd)
            let steps: Int? = stepsDouble.map { Int($0.rounded()) }
            let active = try sumValue(db, hkType: HK.activeEnergy, start: rangeStart, end: rangeEnd)
            let basalDay = try sumValue(db, hkType: HK.basalEnergy, start: rangeStart, end: rangeEnd)
            let dist = try sumValue(db, hkType: HK.distance, start: rangeStart, end: rangeEnd)
            let exerciseMin = try sumValue(db, hkType: HK.exerciseTime, start: rangeStart, end: rangeEnd)
            let standMin = try sumValue(db, hkType: HK.standTime, start: rangeStart, end: rangeEnd)
            let flightsDouble = try sumValue(db, hkType: HK.flights, start: rangeStart, end: rangeEnd)
            let flights: Int? = flightsDouble.map { Int($0.rounded()) }

            let restingHR = try avgValue(db, hkType: HK.restingHR, start: rangeStart, end: rangeEnd)
            let avgHR = try avgValue(db, hkType: HK.heartRate, start: rangeStart, end: rangeEnd)
            let hrv = try avgValue(db, hkType: HK.hrv, start: rangeStart, end: rangeEnd)
            let vo2 = try latestValue(db, hkType: HK.vo2Max, start: rangeStart, end: rangeEnd)
            let (sleepSeconds, sleepEfficiency) = try sleepStats(db, start: rangeStart, end: rangeEnd)

            let activityHasAny = [steps as Any?, active as Any?, basalDay as Any?, dist as Any?,
                                  exerciseMin as Any?, standMin as Any?, flights as Any?,
                                  restingHR as Any?, avgHR as Any?, hrv as Any?, vo2 as Any?,
                                  sleepSeconds as Any?].contains {
                if case Optional<Any>.none = $0 { return false } else { return true }
            }
            if activityHasAny {
                try db.execute(sql: """
                    INSERT INTO activity_metrics_daily
                      (date, step_count, active_energy_kcal, basal_energy_kcal, distance_m,
                       exercise_minutes, stand_minutes, flights_climbed, resting_hr_bpm,
                       avg_hr_bpm, hrv_ms, vo2_max, sleep_seconds, sleep_efficiency, computed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                      sleep_efficiency = excluded.sleep_efficiency,
                      computed_at = excluded.computed_at
                    """, arguments: [
                        date, steps, active, basalDay, dist,
                        exerciseMin, standMin, flights, restingHR,
                        avgHR, hrv, vo2, sleepSeconds, sleepEfficiency, computedAt
                    ])
            }
        }
    }

    // MARK: - SQL primitives (nonisolated: invoked from inside GRDB's synchronous write block)

    nonisolated private func sumValue(_ db: Database, hkType: String, start: Int64, end: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT SUM(value) FROM health_samples_raw
            WHERE is_deleted = 0 AND hk_type = ?
              AND start_at BETWEEN ? AND ?
            """, arguments: [hkType, start, end])
    }

    nonisolated private func avgValue(_ db: Database, hkType: String, start: Int64, end: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT AVG(value) FROM health_samples_raw
            WHERE is_deleted = 0 AND hk_type = ?
              AND start_at BETWEEN ? AND ?
            """, arguments: [hkType, start, end])
    }

    nonisolated private func latestValue(_ db: Database, hkType: String, start: Int64, end: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: """
            SELECT value FROM health_samples_raw
            WHERE is_deleted = 0 AND hk_type = ?
              AND start_at BETWEEN ? AND ?
            ORDER BY start_at DESC LIMIT 1
            """, arguments: [hkType, start, end])
    }

    /// Sleep "night": from yesterday 18:00 local to today 12:00 local.
    /// Counts samples whose categoryValue indicates asleep (1, 3, 4, 5).
    /// Returns (totalAsleepSeconds, efficiency = asleep / (asleep + awake + inBed-only)).
    nonisolated private func sleepStats(_ db: Database, start: Int64, end: Int64) throws -> (Int?, Double?) {
        // We define a "sleep day" as `[date 00:00, date 23:59]` and count samples that overlap.
        // For asleep totals we sum (end_at - start_at) where categoryValue in (1,3,4,5).
        let asleepSeconds = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(MIN(end_at, ?) - MAX(start_at, ?)), 0)
            FROM health_samples_raw
            WHERE is_deleted = 0
              AND hk_type = ?
              AND start_at < ? AND end_at > ?
              AND CAST(value AS INTEGER) IN (1, 3, 4, 5)
            """, arguments: [end, start, HK.sleep, end, start]) ?? 0

        let inBedSeconds = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(MIN(end_at, ?) - MAX(start_at, ?)), 0)
            FROM health_samples_raw
            WHERE is_deleted = 0
              AND hk_type = ?
              AND start_at < ? AND end_at > ?
              AND CAST(value AS INTEGER) = 0
            """, arguments: [end, start, HK.sleep, end, start]) ?? 0

        if asleepSeconds == 0 && inBedSeconds == 0 {
            return (nil, nil)
        }
        let efficiency: Double? = inBedSeconds > 0 ? Double(asleepSeconds) / Double(inBedSeconds) : nil
        return (Int(asleepSeconds), efficiency)
    }

    // MARK: - Date helpers

    private func recentDates(daysBack: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<daysBack).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return formatter.string(from: d)
        }
    }

    private func epochRange(for date: String) -> (Int64, Int64) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let dayStart = formatter.date(from: date) else { return (0, 0) }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return (Int64(dayStart.timeIntervalSince1970), Int64(dayEnd.timeIntervalSince1970) - 1)
    }
}
