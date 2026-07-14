import Foundation
import GRDB

/// Per-day rollup of activity metrics (steps, energy, distance, sleep, …). Written by
/// `DailyAggregator` at the tail of every sync. Dashboard cards read this directly so
/// they never touch `health_samples_raw` at view time.
///
/// NOTE: `sleepEfficiency` and `sourcesJson` are **reserved** — they are retained for
/// forward compatibility only. `sleep_efficiency` is explicitly overwritten on each rebuild
/// via UPSERT and is expected to be NULL until a later stage implements a validated
/// efficiency metric.
struct ActivityMetricsDaily: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "activity_metrics_daily"

    var date: String
    var stepCount: Int?
    var activeEnergyKcal: Double?
    var basalEnergyKcal: Double?
    var distanceM: Double?
    var exerciseMinutes: Double?
    var standMinutes: Double?
    var flightsClimbed: Int?
    var restingHrBpm: Double?
    var avgHrBpm: Double?
    var hrvMs: Double?
    var vo2Max: Double?
    var sleepSeconds: Int?
    var sleepEfficiency: Double?   // reserved — not yet populated (always NULL)
    var sourcesJson: String?       // reserved — not yet populated (always NULL)
    var computedAt: Int64

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case stepCount = "step_count"
        case activeEnergyKcal = "active_energy_kcal"
        case basalEnergyKcal = "basal_energy_kcal"
        case distanceM = "distance_m"
        case exerciseMinutes = "exercise_minutes"
        case standMinutes = "stand_minutes"
        case flightsClimbed = "flights_climbed"
        case restingHrBpm = "resting_hr_bpm"
        case avgHrBpm = "avg_hr_bpm"
        case hrvMs = "hrv_ms"
        case vo2Max = "vo2_max"
        case sleepSeconds = "sleep_seconds"
        case sleepEfficiency = "sleep_efficiency"
        case sourcesJson = "sources_json"
        case computedAt = "computed_at"
    }
}
