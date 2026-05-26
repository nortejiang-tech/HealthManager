import Foundation
import GRDB

/// Period selector for the detail charts. Mirrors Apple Health's 周/月/年.
enum MetricPeriod: String, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }

    /// Width of the *visible* window (inclusive of today on first render). Mirrors
    /// Apple Health's 周/月/年 panes.
    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        }
    }

    /// How many days of history to actually load behind the visible window so the
    /// chart can be scrolled back in time (Apple Health style). The visible pane is
    /// `days`; the user can pan across `historyDays` total.
    var historyDays: Int {
        switch self {
        case .week: return 182    // ~6 months of weekly panning
        case .month: return 365   // 1 year
        case .year: return 1095   // 3 years
        }
    }

    /// Length of the visible window in seconds — fed to `.chartXVisibleDomain`.
    var visibleDomainSeconds: TimeInterval { TimeInterval(days) * 86_400 }

    /// Bucket size used when rolling points into wider buckets. All periods keep
    /// day-level granularity (year view plots every day, not weekly averages).
    var bucketDays: Int { 1 }
}

/// One date-value pair fed to a SwiftUI Chart. `value == nil` means "no data that day".
struct MetricPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double?
    var id: Date { date }
}

/// Aggregation rule used when collapsing day-level rows into a wider bucket
/// (e.g. year view → 1 point per week).
enum SeriesAggregation: Sendable { case sum, average, latest }

/// App-wide cached `DateFormatter`s. Building a `DateFormatter` is expensive, so these are
/// constructed once and reused — important on MainActor hot paths like chart scrolling and
/// day-selection, where labels are recomputed on every frame. Use these instead of
/// allocating `DateFormatter()` inline. (Access from the main actor only.)
enum AppDateFormats {
    /// "M月d日 周三" — selected/short day with weekday (week & month detail headers).
    static let monthDayWeekday = make("M月d日 EEEE")
    /// "2026年5月26日" — fully-qualified day (year detail header).
    static let yearMonthDay = make("yyyy年M月d日")
    /// "2026年5月" — month bucket label (year range).
    static let yearMonth = make("yyyy年M月")
    /// "5月26日" — short day label (week/month range).
    static let monthDay = make("M月d日")
    /// "21:30" — time of a single measurement / sample.
    static let hourMinute = make("HH:mm")

    /// Locale-aware short date+time (e.g. workout rows). Uses styles, not a fixed pattern.
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func make(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        f.dateFormat = pattern
        return f
    }
}

/// Today / hero snapshot used at the top of the dashboard.
struct DashboardSnapshot: Sendable, Equatable {
    var activity = ActivityCardData()
    var heart = HeartCardData()
    var sleep = SleepCardData()
    var body_ = BodyCardData()
    var diet = DietCardData()
    var deficit = DeficitCardData()

    var quality: DataQualityDaily?
    var unackAlertCount: Int = 0
    var criticalAlertCount: Int = 0

    var rawSampleCount: Int = 0
    var lastIngest: Date?
}

// MARK: - Per-card payloads

struct ActivityCardData: Sendable, Equatable {
    var todaySteps: Int?
    var todayActiveKcal: Double?
    var todayDistanceM: Double?
    var todayExerciseMin: Double?
    var last7Days: [DatedDouble] = []
}

struct HeartCardData: Sendable, Equatable {
    var todayRestingHR: Double?
    var todayAvgHR: Double?
    var todayHRV: Double?
    var last7Days: [DatedDouble] = []  // resting HR
}

struct SleepCardData: Sendable, Equatable {
    var lastNightHours: Double?
    var lastNightEfficiency: Double?
    var last7Days: [DatedDouble] = []  // hours
}

struct BodyCardData: Sendable, Equatable {
    var latestWeight: Double?
    var latestBodyFatPct: Double?
    var latestLeanMass: Double?
    var latestBmi: Double?
    var last30Days: [DatedDouble] = []  // weight kg
}

struct DietCardData: Sendable, Equatable {
    var todayCalories: Double = 0
    var todayProtein: Double = 0
    var todayFat: Double = 0
    var todayCarbs: Double = 0
    var meals: [MealRow] = []
    var last7Days: [DatedDouble] = []

    struct MealRow: Sendable, Equatable, Identifiable {
        let id: Int64
        let mealType: String
        let kcal: Double
        let eatenAt: Date
    }
}

struct DeficitCardData: Sendable, Equatable {
    var todayDeficit: Double?
    var todayBurned: Double?
    var todayIntake: Double?
    var last7Days: [DatedDouble] = []
}

struct DatedDouble: Sendable, Equatable, Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

// MARK: - Loader

/// Reads the aggregated tables + a few small live queries to populate the dashboard.
/// All work is dispatched off the main actor via `DatabaseManager.asyncRead`.
struct DashboardLoader {
    let database: DatabaseManager

    static let dateKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func loadSnapshot() async throws -> DashboardSnapshot {
        try await database.asyncRead { db -> DashboardSnapshot in
            var snap = DashboardSnapshot()
            let today = Self.dateKey.string(from: Date())
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            let last7Cutoff = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            let last30Cutoff = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
            let last7Key = Self.dateKey.string(from: last7Cutoff)
            let last30Key = Self.dateKey.string(from: last30Cutoff)

            // -- raw counts / freshness for hero --
            snap.rawSampleCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0") ?? 0
            if let maxIngested = try Int64.fetchOne(db,
                sql: "SELECT MAX(ingested_at) FROM health_samples_raw") {
                snap.lastIngest = Date(timeIntervalSince1970: TimeInterval(maxIngested))
            }

            // -- activity (today + 7d) --
            if let row = try Row.fetchOne(db, sql: """
                SELECT step_count, active_energy_kcal, distance_m, exercise_minutes
                FROM activity_metrics_daily WHERE date = ?
                """, arguments: [today]) {
                snap.activity.todaySteps = row["step_count"]
                snap.activity.todayActiveKcal = row["active_energy_kcal"]
                snap.activity.todayDistanceM = row["distance_m"]
                snap.activity.todayExerciseMin = row["exercise_minutes"]
            }
            snap.activity.last7Days = try Self.dailyValues(
                db, column: "active_energy_kcal", table: "activity_metrics_daily",
                fromKey: last7Key, toKey: today)

            // -- heart (today + 7d) --
            if let row = try Row.fetchOne(db, sql: """
                SELECT resting_hr_bpm, avg_hr_bpm, hrv_ms
                FROM activity_metrics_daily WHERE date = ?
                """, arguments: [today]) {
                snap.heart.todayRestingHR = row["resting_hr_bpm"]
                snap.heart.todayAvgHR = row["avg_hr_bpm"]
                snap.heart.todayHRV = row["hrv_ms"]
            }
            snap.heart.last7Days = try Self.dailyValues(
                db, column: "resting_hr_bpm", table: "activity_metrics_daily",
                fromKey: last7Key, toKey: today)

            // -- sleep (last night = today's row; fall back to most recent non-null) --
            if let row = try Row.fetchOne(db, sql: """
                SELECT sleep_seconds, sleep_efficiency
                FROM activity_metrics_daily
                WHERE sleep_seconds IS NOT NULL AND sleep_seconds > 0
                ORDER BY date DESC LIMIT 1
                """) {
                if let secs: Int = row["sleep_seconds"] {
                    snap.sleep.lastNightHours = Double(secs) / 3600.0
                }
                snap.sleep.lastNightEfficiency = row["sleep_efficiency"]
            }
            let sleepRaw = try Self.dailyValues(
                db, column: "sleep_seconds", table: "activity_metrics_daily",
                fromKey: last7Key, toKey: today)
            snap.sleep.last7Days = sleepRaw.map { DatedDouble(date: $0.date, value: $0.value / 3600.0) }

            // -- body (latest + 30d) --
            if let row = try Row.fetchOne(db, sql: """
                SELECT weight_kg, body_fat_pct, lean_mass_kg, bmi
                FROM body_metrics_daily
                WHERE weight_kg IS NOT NULL OR body_fat_pct IS NOT NULL OR bmi IS NOT NULL
                ORDER BY date DESC LIMIT 1
                """) {
                snap.body_.latestWeight = row["weight_kg"]
                snap.body_.latestBodyFatPct = row["body_fat_pct"]
                snap.body_.latestLeanMass = row["lean_mass_kg"]
                snap.body_.latestBmi = row["bmi"]
            }
            // BMI may live on a different day than weight, so back-fill from the
            // most recent BMI row if the latest weight-row had no BMI.
            if snap.body_.latestBmi == nil,
               let bmiRow = try Row.fetchOne(db, sql: """
                   SELECT bmi FROM body_metrics_daily
                   WHERE bmi IS NOT NULL
                   ORDER BY date DESC LIMIT 1
                   """) {
                snap.body_.latestBmi = bmiRow["bmi"]
            }
            snap.body_.last30Days = try Self.dailyValues(
                db, column: "weight_kg", table: "body_metrics_daily",
                fromKey: last30Key, toKey: today)

            // -- diet (today's meals + macro totals from meal_records) --
            let todayDayStart = Int64(todayStart.timeIntervalSince1970)
            let todayDayEnd = todayDayStart + 86_400
            let mealRows = try Row.fetchAll(db, sql: """
                SELECT id, meal_type, calories_kcal, protein_g, fat_g, carbs_g, eaten_at
                FROM meal_records
                WHERE eaten_at >= ? AND eaten_at < ?
                ORDER BY eaten_at ASC
                """, arguments: [todayDayStart, todayDayEnd])
            for r in mealRows {
                let kcal: Double = r["calories_kcal"] ?? 0
                let p: Double = r["protein_g"] ?? 0
                let f: Double = r["fat_g"] ?? 0
                let c: Double = r["carbs_g"] ?? 0
                snap.diet.todayCalories += kcal
                snap.diet.todayProtein += p
                snap.diet.todayFat += f
                snap.diet.todayCarbs += c
                let eaten: Int64 = r["eaten_at"] ?? todayDayStart
                snap.diet.meals.append(.init(
                    id: r["id"] ?? 0,
                    mealType: Self.localizedMealType(r["meal_type"] ?? ""),
                    kcal: kcal,
                    eatenAt: Date(timeIntervalSince1970: TimeInterval(eaten))
                ))
            }

            // -- diet 7d series (per-day total kcal) --
            let dietStart = Int64(last7Cutoff.timeIntervalSince1970)
            let dietEnd = todayDayEnd
            let dietRows = try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m-%d', datetime(eaten_at, 'unixepoch', 'localtime')) AS d,
                       SUM(COALESCE(calories_kcal, 0)) AS kcal
                FROM meal_records
                WHERE eaten_at >= ? AND eaten_at < ?
                GROUP BY d
                ORDER BY d ASC
                """, arguments: [dietStart, dietEnd])
            snap.diet.last7Days = dietRows.compactMap { r in
                guard let s: String = r["d"], let d = Self.dateKey.date(from: s) else { return nil }
                return DatedDouble(date: d, value: r["kcal"] ?? 0)
            }

            // -- deficit (active + basal − intake) for today + last 7 --
            if let actRow = try Row.fetchOne(db, sql: """
                SELECT active_energy_kcal, basal_energy_kcal
                FROM activity_metrics_daily WHERE date = ?
                """, arguments: [today]) {
                let active: Double? = actRow["active_energy_kcal"]
                let basal: Double? = actRow["basal_energy_kcal"]
                let burned: Double? = (active ?? 0) + (basal ?? 0) > 0 ? (active ?? 0) + (basal ?? 0) : nil
                snap.deficit.todayBurned = burned
                snap.deficit.todayIntake = snap.diet.todayCalories > 0 ? snap.diet.todayCalories : nil
                if let b = burned {
                    snap.deficit.todayDeficit = b - snap.diet.todayCalories
                }
            } else if snap.diet.todayCalories > 0 {
                snap.deficit.todayIntake = snap.diet.todayCalories
            }
            snap.deficit.last7Days = try Self.deficitSeries(
                db, fromKey: last7Key, toKey: today)

            // -- quality + alerts --
            snap.quality = try DataQualityDaily.fetchOne(db, key: today)
            snap.unackAlertCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0") ?? 0
            snap.criticalAlertCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0 AND severity = 'critical'") ?? 0

            return snap
        }
    }

    // MARK: - Period series for detail view

    /// Load a window of points for a single metric, padding missing days with `value=nil`.
    /// `column` must be a known daily-table column; `table` is one of the daily aggregate tables.
    func loadSeries(table: String, column: String, period: MetricPeriod,
                    aggregation: SeriesAggregation = .latest) async throws -> [MetricPoint] {
        let database = self.database
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let historyDays = period.historyDays
        let cutoff = cal.date(byAdding: .day, value: -(historyDays - 1), to: todayStart) ?? todayStart
        let fromKey = Self.dateKey.string(from: cutoff)
        let toKey = Self.dateKey.string(from: todayStart)

        let raw = try await database.asyncRead { db in
            try Self.dailyValues(db, column: column, table: table, fromKey: fromKey, toKey: toKey)
        }

        // Fill every day in the loaded history (so empty days render as gaps, not
        // "missing dates"). The view shows a scrollable window over this full range.
        var byDate: [Date: Double] = [:]
        for r in raw { byDate[cal.startOfDay(for: r.date)] = r.value }
        var points: [MetricPoint] = []
        for offset in 0..<historyDays {
            guard let d = cal.date(byAdding: .day, value: -(historyDays - 1 - offset), to: todayStart) else { continue }
            points.append(MetricPoint(date: d, value: byDate[cal.startOfDay(for: d)]))
        }

        if period.bucketDays > 1 {
            points = bucket(points: points, bucketDays: period.bucketDays, aggregation: aggregation)
        }
        return points
    }

    /// Per-day diet calories, padded to the full window with `nil` values on missing days.
    func loadDietSeries(period: MetricPeriod) async throws -> [MetricPoint] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let historyDays = period.historyDays
        guard let cutoff = cal.date(byAdding: .day, value: -(historyDays - 1), to: todayStart) else {
            return []
        }
        let from = Int64(cutoff.timeIntervalSince1970)
        let toExclusive = Int64(todayStart.timeIntervalSince1970) + 86_400

        let raw: [DatedDouble] = try await database.asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m-%d', datetime(eaten_at, 'unixepoch', 'localtime')) AS d,
                       SUM(COALESCE(calories_kcal, 0)) AS kcal
                FROM meal_records
                WHERE eaten_at >= ? AND eaten_at < ?
                GROUP BY d
                ORDER BY d ASC
                """, arguments: [from, toExclusive])
            return rows.compactMap { row in
                guard let s: String = row["d"], let d = Self.dateKey.date(from: s) else { return nil }
                return DatedDouble(date: d, value: row["kcal"] ?? 0)
            }
        }
        return Self.fillAndBucket(raw, period: period, aggregation: .sum, daysOverride: historyDays)
    }

    /// Per-day breakdown of the deficit calculation. Used by the detail view when a
    /// single day is selected: shows the user how 缺口 = 基础代谢 + 活动消耗 − 摄入.
    /// All four values are kcal; `deficit` is the same number rendered on the chart.
    struct DeficitBreakdown: Equatable {
        let date: Date
        let basal: Double?     // basal_energy_kcal (基础代谢)
        let active: Double?    // active_energy_kcal (活动消耗)
        let intake: Double?    // SUM(meal_records.calories_kcal) over the local day
        var deficit: Double {
            (active ?? 0) + (basal ?? 0) - (intake ?? 0)
        }
    }

    /// Look up the breakdown for a single local day. Returns nil if neither activity
    /// nor intake exists (matches the chart-side sparsity rule).
    func loadDeficitBreakdown(for date: Date) async throws -> DeficitBreakdown? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let key = Self.dateKey.string(from: day)

        return try await database.asyncRead { db in
            let actRow = try Row.fetchOne(db, sql: """
                SELECT active_energy_kcal, basal_energy_kcal
                FROM activity_metrics_daily
                WHERE date = ?
                """, arguments: [key])
            let intakeRow = try Row.fetchOne(db, sql: """
                SELECT SUM(COALESCE(calories_kcal, 0)) AS intake
                FROM meal_records
                WHERE strftime('%Y-%m-%d', datetime(eaten_at, 'unixepoch', 'localtime')) = ?
                """, arguments: [key])

            let basal: Double? = actRow?["basal_energy_kcal"]
            let active: Double? = actRow?["active_energy_kcal"]
            let intake: Double? = {
                let v: Double? = intakeRow?["intake"]
                // SUM with no rows returns NULL → nil; SUM with rows but all-NULL → 0.
                return (v ?? 0) > 0 ? v : nil
            }()

            if basal == nil && active == nil && intake == nil {
                return nil
            }
            return DeficitBreakdown(date: day, basal: basal, active: active, intake: intake)
        }
    }

    /// A single raw body-composition sample (one weigh-in / one reading) used by the
    /// detail view to list everything measured on an inspected day.
    struct BodyMeasurementSample: Identifiable, Equatable, Sendable {
        let id: String
        let time: Date
        let value: Double
        let source: String
    }

    /// All raw samples of `hkType` recorded on the local day containing `day`, ordered
    /// by time. Powers the "当日全部测量" list when the user selects a day in a body chart.
    func loadDayMeasurements(hkType: String, day: Date) async throws -> [BodyMeasurementSample] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let s = Int64(start.timeIntervalSince1970)
        let e = Int64(end.timeIntervalSince1970) - 1

        return try await database.asyncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sample_uuid, start_at, value, source_name, source_origin
                FROM health_samples_raw
                WHERE hk_type = ? AND is_deleted = 0 AND start_at BETWEEN ? AND ?
                ORDER BY start_at ASC
                """, arguments: [hkType, s, e])
            return rows.map { r in
                let origin = SourceAttribution.Origin(rawValue: r["source_origin"] ?? "unknown")?.label
                let sname: String? = r["source_name"]
                return BodyMeasurementSample(
                    id: r["sample_uuid"] ?? UUID().uuidString,
                    time: Date(timeIntervalSince1970: TimeInterval(r["start_at"] ?? 0)),
                    value: r["value"] ?? 0,
                    source: origin ?? sname ?? "未知来源"
                )
            }
        }
    }

    /// Per-day deficit (active + basal − intake), padded to the full window.
    /// Returns `nil` on a day when there's neither activity nor intake (to keep the chart sparse).
    func loadDeficitSeries(period: MetricPeriod) async throws -> [MetricPoint] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let historyDays = period.historyDays
        guard let cutoff = cal.date(byAdding: .day, value: -(historyDays - 1), to: todayStart) else {
            return []
        }
        let fromKey = Self.dateKey.string(from: cutoff)
        let toKey = Self.dateKey.string(from: todayStart)

        let raw: [DatedDouble] = try await database.asyncRead { db in
            try Self.deficitSeries(db, fromKey: fromKey, toKey: toKey)
        }
        return Self.fillAndBucket(raw, period: period, aggregation: .average, daysOverride: historyDays)
    }

    // MARK: - Window fill helpers

    static func fillAndBucket(_ raw: [DatedDouble], period: MetricPeriod,
                              aggregation: SeriesAggregation,
                              daysOverride: Int? = nil) -> [MetricPoint] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let span = daysOverride ?? period.days
        var byDate: [Date: Double] = [:]
        for r in raw { byDate[cal.startOfDay(for: r.date)] = r.value }
        var points: [MetricPoint] = []
        for offset in 0..<span {
            guard let d = cal.date(byAdding: .day, value: -(span - 1 - offset), to: todayStart) else { continue }
            points.append(MetricPoint(date: d, value: byDate[cal.startOfDay(for: d)]))
        }
        if period.bucketDays > 1 {
            points = bucketStatic(points: points, bucketDays: period.bucketDays, aggregation: aggregation)
        }
        return points
    }

    static func bucketStatic(points: [MetricPoint], bucketDays: Int,
                             aggregation: SeriesAggregation) -> [MetricPoint] {
        var buckets: [[MetricPoint]] = []
        var current: [MetricPoint] = []
        for (i, p) in points.enumerated() {
            current.append(p)
            if current.count == bucketDays || i == points.count - 1 {
                buckets.append(current)
                current = []
            }
        }
        return buckets.map { group in
            let values = group.compactMap { $0.value }
            let value: Double?
            if values.isEmpty {
                value = nil
            } else {
                switch aggregation {
                case .sum: value = values.reduce(0, +)
                case .average: value = values.reduce(0, +) / Double(values.count)
                case .latest: value = values.last
                }
            }
            let midpoint = group[group.count / 2].date
            return MetricPoint(date: midpoint, value: value)
        }
    }

    // MARK: - SQL helpers

    /// Convert a `[fromKey, toKey]` (inclusive, yyyy-MM-dd) window into a half-open epoch
    /// range `[start-of-fromKey, start-of-(toKey+1day))` for indexed `eaten_at` filters.
    static func epochBounds(fromKey: String, toKey: String) -> (Int64, Int64) {
        let cal = Calendar.current
        guard let fromDate = dateKey.date(from: fromKey),
              let toDate = dateKey.date(from: toKey) else {
            return (0, Int64.max)
        }
        let start = Int64(cal.startOfDay(for: fromDate).timeIntervalSince1970)
        let endDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate)) ?? toDate
        return (start, Int64(endDay.timeIntervalSince1970))
    }

    static func dailyValues(_ db: Database, column: String, table: String,
                            fromKey: String, toKey: String) throws -> [DatedDouble] {
        // Whitelist table/column to keep this SQL injection-safe (callers are ours only).
        let allowedTables: Set<String> = ["activity_metrics_daily", "body_metrics_daily"]
        guard allowedTables.contains(table) else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT date, \(column) AS val FROM \(table)
            WHERE date BETWEEN ? AND ? AND \(column) IS NOT NULL
            ORDER BY date ASC
            """, arguments: [fromKey, toKey])
        return rows.compactMap { row in
            guard let s: String = row["date"], let d = Self.dateKey.date(from: s) else { return nil }
            let v: Double = row["val"] ?? 0
            return DatedDouble(date: d, value: v)
        }
    }

    static func deficitSeries(_ db: Database, fromKey: String, toKey: String) throws -> [DatedDouble] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT date,
                   COALESCE(active_energy_kcal, 0) + COALESCE(basal_energy_kcal, 0) AS burned
            FROM activity_metrics_daily
            WHERE date BETWEEN ? AND ?
            ORDER BY date ASC
            """, arguments: [fromKey, toKey])
        // Get intake per day from meal_records — bounded to the same window so we hit the
        // `idx_meal_eaten_at` index instead of scanning/aggregating the whole meal table.
        let (fromEpoch, toExclusive) = Self.epochBounds(fromKey: fromKey, toKey: toKey)
        let intakeRows = try Row.fetchAll(db, sql: """
            SELECT strftime('%Y-%m-%d', datetime(eaten_at, 'unixepoch', 'localtime')) AS date,
                   SUM(COALESCE(calories_kcal, 0)) AS intake
            FROM meal_records
            WHERE eaten_at >= ? AND eaten_at < ?
            GROUP BY date
            """, arguments: [fromEpoch, toExclusive])
        var intakeMap: [String: Double] = [:]
        for r in intakeRows {
            if let d: String = r["date"] {
                intakeMap[d] = r["intake"] ?? 0
            }
        }
        var out: [DatedDouble] = []
        for row in rows {
            guard let key: String = row["date"], let d = Self.dateKey.date(from: key) else { continue }
            let burned: Double = row["burned"] ?? 0
            let intake = intakeMap[key] ?? 0
            // Only emit a point when there's meaningful data on either side.
            if burned > 0 || intake > 0 {
                out.append(DatedDouble(date: d, value: burned - intake))
            }
        }
        return out
    }

    // MARK: - Bucketing

    private func bucket(points: [MetricPoint], bucketDays: Int,
                        aggregation: SeriesAggregation) -> [MetricPoint] {
        var buckets: [[MetricPoint]] = []
        var current: [MetricPoint] = []
        for (i, p) in points.enumerated() {
            current.append(p)
            if current.count == bucketDays || i == points.count - 1 {
                buckets.append(current)
                current = []
            }
        }
        return buckets.map { group in
            let values = group.compactMap { $0.value }
            let value: Double?
            if values.isEmpty {
                value = nil
            } else {
                switch aggregation {
                case .sum: value = values.reduce(0, +)
                case .average: value = values.reduce(0, +) / Double(values.count)
                case .latest: value = values.last
                }
            }
            let midpoint = group[group.count / 2].date
            return MetricPoint(date: midpoint, value: value)
        }
    }

    // MARK: - Misc

    static func localizedMealType(_ key: String) -> String {
        switch key {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        case "snack": return "加餐"
        default: return key
        }
    }
}
