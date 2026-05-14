import Foundation
import GRDB

/// Per-day rollup of body composition (weight / body fat / BMI / lean mass / …).
/// Each metric is the *latest* sample for the day (instantaneous, not cumulative).
struct BodyMetricsDaily: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "body_metrics_daily"

    var date: String
    var weightKg: Double?
    var bodyFatPct: Double?
    var bmi: Double?
    var leanMassKg: Double?
    var heightM: Double?
    var basalEnergyKcal: Double?
    var visceralFatLevel: Double?
    var muscleMassKg: Double?
    var waterPct: Double?
    var proteinPct: Double?
    var sourcesJson: String?
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
