import Foundation

/// Read-only metadata describing one bridge tool. Pure data: no I/O, no HealthKit,
/// no MCP transport and no business logic.
public struct BridgeToolDescriptor: Equatable, Hashable {
    /// Stable tool identifier used by callers to select the tool.
    public let name: String
    /// Concise English description of what the tool reads and what it does not do.
    public let description: String
    /// Every argument the tool accepts.
    public let arguments: [String]
    /// Arguments that must be supplied. Always a subset of `arguments`.
    public let required: [String]

    public init(name: String, description: String, arguments: [String], required: [String]) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.required = required
    }
}

/// Static catalog of the nine read-only HealthBridge tools.
public enum BridgeToolCatalog {
    public static let descriptors: [BridgeToolDescriptor] = [
        BridgeToolDescriptor(
            name: "health_sync_status",
            description: "Read-only export status: reports the last completed export time and, per source, the newest stored sample timestamp so callers can tell export freshness apart from sample freshness. A recent export time does not imply recent samples, and a stale source only means no newer data was exported, not that none exists on the device. Takes no arguments and never triggers a sync, a re-export or a device read.",
            arguments: [],
            required: []
        ),
        BridgeToolDescriptor(
            name: "health_daily_summary",
            description: "Read-only summary for exactly one local calendar date (yyyy-MM-dd): stored activity, body and quality rows; logged meal detail; medication plans and date-filtered logs; and deterministic daily nutrition plus energy balance. The calorie deficit is emitted only when all logged meal calories, active energy and basal energy are finite non-negative values; it is basal plus active energy minus intake, and unknown inputs remain null with a status. Values and quality records are returned as stored; coverage does not prove that a day is complete. Only the `date` argument is accepted - no ranges, no metric selection, no cross-day rollup.",
            arguments: ["date"],
            required: ["date"]
        ),
        BridgeToolDescriptor(
            name: "health_metric_history",
            description: "Read-only daily series for one metric over an inclusive date range (yyyy-MM-dd, interpreted in the source timezone). Supported metrics: weight, steps, active_energy, exercise_minutes, heart_rate, resting_heart_rate, hrv_daily_mean, sleep_duration, calorie_intake, calorie_deficit. Calorie intake requires complete logged meal snapshots; calorie deficit additionally requires valid basal and active energy and is calculated as basal plus active energy minus intake. Days with no stored or incomplete data are preserved as explicit gaps rather than interpolated, dropped or carried forward. hrv_daily_mean is the arithmetic daily mean of HRV samples and is reported separately from any nightly median, so the two are never mixed.",
            arguments: ["metric", "from", "to"],
            required: ["metric", "from", "to"]
        ),
        BridgeToolDescriptor(
            name: "health_sleep",
            description: "Read-only sleep record for one wake date (yyyy-MM-dd): the window runs from 18:00 on the previous day to 18:00 on the given date in the source timezone. Where several sources cover the window, a fixed source precedence picks one primary record and overlapping segments from the same source are deduplicated, so a night is counted once. Unspecified or conflicting stages within the selected source are marked; other sources are listed but are not fused. Night HRV median is reported as a distinct field from the daily HRV mean. Snapshot only: no live, real-time or ongoing-session sleep is provided.",
            arguments: ["date"],
            required: ["date"]
        ),
        BridgeToolDescriptor(
            name: "health_workouts",
            description: "Read-only paginated list of stored workout sessions between two inclusive dates (yyyy-MM-dd, source timezone): type, start and end, duration, energy and distance as exported. `limit` must be between 1 and 1000 and `offset` must be 0 or greater; paging is stable over the stored set. Values are historical records only - no live session, no device command and no quality guarantee beyond the recorded source data.",
            arguments: ["from", "to", "offset", "limit"],
            required: ["from", "to"]
        ),
        BridgeToolDescriptor(
            name: "health_meals",
            description: "Read-only paginated list of stored meal records between two inclusive dates (yyyy-MM-dd, source timezone): meal time, items and logged macronutrient and calorie totals as exported. `limit` must be between 1 and 1000 and `offset` must be 0 or greater. Entries reflect what was logged by the source app and are not verified nutrition advice, dietary guidance or an estimate of actual intake.",
            arguments: ["from", "to", "offset", "limit"],
            required: ["from", "to"]
        ),
        BridgeToolDescriptor(
            name: "health_medications",
            description: "Read-only paginated view of stored medication data between two inclusive dates (yyyy-MM-dd, source timezone): all stored medication plans and date-filtered medication logs (the date filter uses scheduled_at). A plan describes intended dosage and schedule only and is not evidence that a dose was taken; actual administration is represented only by the corresponding log entries, so plans and logs must be read separately and never treated as the same thing. `limit` must be between 1 and 1000 and `offset` must be 0 or greater. No dosing advice and no write or reminder behavior.",
            arguments: ["from", "to", "offset", "limit"],
            required: ["from", "to"]
        ),
        BridgeToolDescriptor(
            name: "health_records",
            description: "Read-only paginated access to the normalized local record store between two inclusive dates (yyyy-MM-dd, source timezone). Supported categories: health_samples_raw, meal_records, meal_items, medication_plans, medication_logs, activity_metrics_daily, body_metrics_daily, data_quality_daily. Results are the normalized and de-duplicated rows this bridge exported, not a lossless HealthKit export: source fields outside the normalized schema, store metadata and data the bridge chose not to mirror are absent. `limit` must be between 1 and 1000 and `offset` must be 0 or greater.",
            arguments: ["category", "from", "to", "source", "type", "offset", "limit"],
            required: ["category", "from", "to"]
        ),
        BridgeToolDescriptor(
            name: "health_compare",
            description: "Read-only deterministic comparison of one metric between two inclusive date ranges (A: fromA/toA, B: fromB/toB, yyyy-MM-dd, source timezone). For each range returns the same descriptive statistics - count of days with data, mean and median, plus the difference between period means - computed only from days that have stored values; missing days are excluded from every statistic rather than imputed, so ranges with different coverage are not directly comparable in absolute terms. Comparison is descriptive only: it makes no causal, clinical, treatment or trend-significance claim.",
            arguments: ["metric", "fromA", "toA", "fromB", "toB"],
            required: ["metric", "fromA", "toA", "fromB", "toB"]
        )
    ]
}
