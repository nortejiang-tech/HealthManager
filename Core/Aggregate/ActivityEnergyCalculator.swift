import Foundation
import GRDB

/// Computes the app's canonical "active energy" value for a local day.
///
/// HealthKit can expose exercise calories through two paths:
/// - `HKQuantityTypeIdentifierActiveEnergyBurned`
/// - `HKWorkout.totalEnergyBurned`, persisted here as `extra_json.totalEnergyKcal`
///
/// Some sources write both, some only write workout energy. We use quantity samples as
/// the baseline, then add only the workout calories that are not already represented
/// by overlapping active-energy samples from the chosen quantity source.
enum ActivityEnergyCalculator {
    static let activeEnergyType = "HKQuantityTypeIdentifierActiveEnergyBurned"
    static let workoutType = "HKWorkoutTypeIdentifier"

    struct DominantSourceSum: Equatable {
        let value: Double
        let sourceKey: String?
    }

    static func dailyActiveEnergyKcal(db: Database, start: Int64, end: Int64) throws -> Double {
        let quantity = try dominantCumulativeSum(
            db: db,
            hkType: activeEnergyType,
            start: start,
            end: end
        )
        let supplementalWorkout = try workoutEnergySupplement(
            db: db,
            start: start,
            end: end,
            quantitySourceKey: quantity.sourceKey
        )
        return quantity.value + supplementalWorkout
    }

    /// Dominant-source sum for one cumulative type in [start, end]. Group raw samples by
    /// source bundle, pick the source with highest attribution priority (tie-break:
    /// larger sum), and return only that source's total.
    static func cumulativeSum(db: Database, hkType: String, start: Int64, end: Int64) throws -> Double {
        try dominantCumulativeSum(db: db, hkType: hkType, start: start, end: end).value
    }

    static func dominantCumulativeSum(
        db: Database,
        hkType: String,
        start: Int64,
        end: Int64
    ) throws -> DominantSourceSum {
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
        var bestSourceKey: String?
        for r in rows {
            let bid: String = r["bid"] ?? ""
            let sname: String = r["sname"] ?? ""
            let s: Double = r["s"] ?? 0
            let origin = SourceAttribution.classify(bundleId: bid, sourceName: sname)
            let p = origin.cumulativePriority
            if p > bestPriority || (p == bestPriority && s > bestSum) {
                bestPriority = p
                bestSum = s
                bestSourceKey = bid
            }
        }
        return DominantSourceSum(value: bestSum, sourceKey: bestSourceKey)
    }

    private struct WorkoutEnergyRow {
        let startAt: Int64
        let endAt: Int64
        let energyKcal: Double
    }

    private static func workoutEnergySupplement(
        db: Database,
        start: Int64,
        end: Int64,
        quantitySourceKey: String?
    ) throws -> Double {
        let workouts = try workoutEnergyRows(db: db, start: start, end: end)
        guard !workouts.isEmpty else { return 0 }

        var supplement: Double = 0
        for workout in workouts {
            let represented = try overlappingActiveEnergy(
                db: db,
                workoutStart: workout.startAt,
                workoutEnd: workout.endAt,
                quantitySourceKey: quantitySourceKey
            )
            supplement += max(0, workout.energyKcal - represented)
        }
        return supplement
    }

    private static func workoutEnergyRows(db: Database, start: Int64, end: Int64) throws -> [WorkoutEnergyRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT start_at, end_at, extra_json
            FROM health_samples_raw
            WHERE hk_type = ?
              AND is_deleted = 0
              AND start_at BETWEEN ? AND ?
            ORDER BY start_at ASC
            """, arguments: [workoutType, start, end])

        return rows.compactMap { row in
            guard let json: String = row["extra_json"],
                  let energy = energyKcal(fromExtraJson: json),
                  energy > 0
            else { return nil }
            return WorkoutEnergyRow(
                startAt: row["start_at"] ?? 0,
                endAt: row["end_at"] ?? 0,
                energyKcal: energy
            )
        }
    }

    private static func overlappingActiveEnergy(
        db: Database,
        workoutStart: Int64,
        workoutEnd: Int64,
        quantitySourceKey: String?
    ) throws -> Double {
        guard let quantitySourceKey else { return 0 }
        let rows = try Row.fetchAll(db, sql: """
            SELECT value, start_at, end_at
            FROM health_samples_raw
            WHERE hk_type = ?
              AND is_deleted = 0
              AND COALESCE(source_bundle_id, 'unknown') = ?
              AND start_at <= ?
              AND end_at >= ?
            """, arguments: [
                activeEnergyType,
                quantitySourceKey,
                workoutEnd,
                workoutStart
            ])

        return rows.reduce(0) { partial, row in
            let value: Double = row["value"] ?? 0
            let startAt: Int64 = row["start_at"] ?? workoutStart
            let endAt: Int64 = row["end_at"] ?? workoutEnd
            if endAt <= startAt {
                return (startAt >= workoutStart && startAt <= workoutEnd) ? partial + value : partial
            }
            let sampleDuration = max(1, endAt - startAt)
            let overlap = max(0, min(endAt, workoutEnd) - max(startAt, workoutStart))
            return partial + value * (Double(overlap) / Double(sampleDuration))
        }
    }

    private static func energyKcal(fromExtraJson json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = dict["totalEnergyKcal"]
        else { return nil }

        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}
