import Foundation
import GRDB

/// Per-day rollup of body composition (weight / body fat / BMI / lean mass / …).
/// Weight / body-fat / BMI / lean-mass are the *daily average* of that day's samples;
/// height is the latest reading.
///
/// NOTE: `visceralFatLevel`, `muscleMassKg`, `waterPct`, `proteinPct` and `sourcesJson` are
/// **reserved** — the schema carries them but `DailyAggregator` currently writes them as NULL
/// (no corresponding HealthKit quantity is read yet; intended for manual entry / extended
/// scales per PRD §4.2). Treat them as optional/absent at every read site.
struct BodyMetricsDaily: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "body_metrics_daily"

    var date: String
    var weightKg: Double?
    var bodyFatPct: Double?
    var bmi: Double?
    var leanMassKg: Double?
    var heightM: Double?
    var basalEnergyKcal: Double?
    var visceralFatLevel: Double?  // reserved — not yet populated (always NULL)
    var muscleMassKg: Double?      // reserved — not yet populated (always NULL)
    var waterPct: Double?          // reserved — not yet populated (always NULL)
    var proteinPct: Double?        // reserved — not yet populated (always NULL)
    var sourcesJson: String?       // reserved — not yet populated (always NULL)
    var computedAt: Int64

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
        case bmi
        case leanMassKg = "lean_mass_kg"
        case heightM = "height_m"
        case basalEnergyKcal = "basal_energy_kcal"
        case visceralFatLevel = "visceral_fat_level"
        case muscleMassKg = "muscle_mass_kg"
        case waterPct = "water_pct"
        case proteinPct = "protein_pct"
        case sourcesJson = "sources_json"
        case computedAt = "computed_at"
    }
}
