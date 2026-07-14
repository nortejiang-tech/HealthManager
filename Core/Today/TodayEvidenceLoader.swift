import Foundation
import GRDB

enum TodayEvidenceLoaderError: Error, Equatable, Sendable {
    case invalidLocalDayWindow
    case invalidMealType(String)
    case invalidMealProvenance(String)
    case invalidMedicationAction(String)
    case invalidAlertSeverity(String)
}

struct TodayEvidenceSnapshot: Equatable, Sendable {
    let dayStart: Date
    let dayEndExclusive: Date
    let dayKey: String
    let dailyAggregate: TodayDailyAggregateEvidence
    let timelineEntries: [TodayTimelineEvidenceEntry]
    let nutrition: MealNutritionEvidenceWindow
    let energyBalance: EnergyBalanceEvidence
    let dataQuality: TodayDataQualityEvidence
    let sourceCoverage: [TodaySourceCoverageEvidence]
}

struct TodayDailyAggregateEvidence: Equatable, Sendable {
    let wasComputed: Bool
    let computedAt: Date?
    let asleepSeconds: Int?
    let steps: Int?
    let activeEnergyKcal: Double?
    let basalEnergyKcal: Double?
    let distanceM: Double?
    let exerciseMinutes: Double?

    static let unavailable = TodayDailyAggregateEvidence(
        wasComputed: false,
        computedAt: nil,
        asleepSeconds: nil,
        steps: nil,
        activeEnergyKcal: nil,
        basalEnergyKcal: nil,
        distanceM: nil,
        exerciseMinutes: nil
    )
}

enum TodayTimelineTimeBasis: Equatable, Sendable {
    case eatenTime
    case actionTime
    case scheduledFallback
}

enum TodayMealKind: Equatable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack

    init(_ stored: MealRecord.MealType) {
        switch stored {
        case .breakfast: self = .breakfast
        case .lunch: self = .lunch
        case .dinner: self = .dinner
        case .snack: self = .snack
        }
    }
}

enum TodayMealProvenanceKind: Equatable, Sendable {
    case manual
    case aiEstimate
    case nutritionDatabase
    case nutritionLabel

    init(_ stored: MealItemRecord.ProvenanceKind) {
        switch stored {
        case .manual: self = .manual
        case .aiEstimate: self = .aiEstimate
        case .nutritionDatabase: self = .nutritionDatabase
        case .nutritionLabel: self = .nutritionLabel
        }
    }
}

struct TodayMealEvidence: Equatable, Sendable {
    let id: Int64
    let mealType: TodayMealKind
    let eatenAt: Date
    let timelineAt: Date
    let timeBasis: TodayTimelineTimeBasis
    let totals: MealNutritionTotals
    let itemCount: Int
    let provenanceKinds: [TodayMealProvenanceKind]
    let hasUserEditedItem: Bool
}

enum TodayMedicationAction: Equatable, Sendable {
    case taken
    case skipped
    case deferred

    init(_ stored: MedicationLog.Action) {
        switch stored {
        case .taken: self = .taken
        case .skipped: self = .skipped
        case .deferred: self = .deferred
        }
    }
}

struct TodayMedicationEvidence: Equatable, Sendable {
    let id: Int64
    let planID: Int64?
    let planName: String?
    let scheduledAt: Date
    let actionAt: Date?
    let timelineAt: Date
    let timeBasis: TodayTimelineTimeBasis
    let action: TodayMedicationAction
    let dosageMg: Double?
}

enum TodayTimelineEvidenceEntry: Equatable, Sendable {
    case meal(TodayMealEvidence)
    case medication(TodayMedicationEvidence)

    var id: String {
        switch self {
        case let .meal(value): return "meal-\(value.id)"
        case let .medication(value): return "medication-\(value.id)"
        }
    }

    var timelineAt: Date {
        switch self {
        case let .meal(value): return value.timelineAt
        case let .medication(value): return value.timelineAt
        }
    }

    var timeBasis: TodayTimelineTimeBasis {
        switch self {
        case let .meal(value): return value.timeBasis
        case let .medication(value): return value.timeBasis
        }
    }

    fileprivate var kindSortRank: Int {
        switch self {
        case .meal: return 0
        case .medication: return 1
        }
    }

    fileprivate var persistedID: Int64 {
        switch self {
        case let .meal(value): return value.id
        case let .medication(value): return value.id
        }
    }
}

enum TodayDataAlertSeverity: Equatable, Sendable {
    case info
    case warning
    case critical

    init(_ stored: MissingDataAlert.Severity) {
        switch stored {
        case .info: self = .info
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }
}

struct TodayDataAlertEvidence: Equatable, Sendable {
    let id: Int64
    let metric: String
    let severity: TodayDataAlertSeverity
    let message: String?
    let createdAt: Date
}

struct TodayDataQualityEvidence: Equatable, Sendable {
    let wasReconciled: Bool
    let computedAt: Date?
    let completenessScore: Double?
    let freshnessScore: Double?
    let conflictScore: Double?
    let missingMetricKeys: [String]?
    let alerts: [TodayDataAlertEvidence]
}

enum TodaySourceOrigin: Hashable, Sendable {
    case garmin
    case xiaomiMijia
    case xiaomiSports
    case apple
    case hutool
    case manual
    case unknown

    init(rawValue: String?) {
        switch rawValue {
        case SourceAttribution.Origin.garmin.rawValue: self = .garmin
        case SourceAttribution.Origin.xiaomiMijia.rawValue: self = .xiaomiMijia
        case SourceAttribution.Origin.xiaomiSports.rawValue: self = .xiaomiSports
        case SourceAttribution.Origin.apple.rawValue: self = .apple
        case SourceAttribution.Origin.hutool.rawValue: self = .hutool
        case SourceAttribution.Origin.manual.rawValue: self = .manual
        default: self = .unknown
        }
    }

    fileprivate var sortRank: Int {
        switch self {
        case .garmin: return 0
        case .xiaomiMijia: return 1
        case .xiaomiSports: return 2
        case .apple: return 3
        case .hutool: return 4
        case .manual: return 5
        case .unknown: return 6
        }
    }
}

struct TodaySourceCoverageEvidence: Equatable, Sendable {
    let origin: TodaySourceOrigin
    let sourceName: String?
    let sampleCount: Int
    let lastIngestedAt: Date?
}

struct TodayEvidenceLoader: Sendable {
    let database: DatabaseManager

    func load(
        forLocalDay day: Date,
        calendar: Calendar = .current
    ) async throws -> TodayEvidenceSnapshot {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEndExclusive = calendar.date(byAdding: .day, value: 1, to: dayStart),
              dayEndExclusive > dayStart
        else {
            throw TodayEvidenceLoaderError.invalidLocalDayWindow
        }

        let dayKey = Self.dayKey(for: dayStart, calendar: calendar)
        let startEpoch = Int64(dayStart.timeIntervalSince1970)
        let endEpoch = Int64(dayEndExclusive.timeIntervalSince1970)

        return try await database.asyncRead { db in
            let aggregate = try Self.loadDailyAggregate(db: db, dayKey: dayKey)
            let nutrition = try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: dayStart,
                throughLocalDay: dayStart,
                calendar: calendar
            )
            let meals = try Self.loadMeals(db: db, startEpoch: startEpoch, endEpoch: endEpoch)
            let medications = try Self.loadMedications(
                db: db,
                startEpoch: startEpoch,
                endEpoch: endEpoch
            )
            let timelineEntries = Self.sortedTimeline(
                meals.map(TodayTimelineEvidenceEntry.meal)
                    + medications.map(TodayTimelineEvidenceEntry.medication)
            )
            let alerts = try Self.loadAlerts(db: db, dayKey: dayKey)
            let dataQuality = try Self.loadDataQuality(db: db, dayKey: dayKey, alerts: alerts)
            let sourceCoverage = try Self.loadSourceCoverage(
                db: db,
                startEpoch: startEpoch,
                endEpoch: endEpoch
            )
            let energyBalance = EnergyBalanceEvidence(
                activeKcal: aggregate.activeEnergyKcal,
                basalKcal: aggregate.basalEnergyKcal,
                intake: nutrition.calories
            )

            return TodayEvidenceSnapshot(
                dayStart: dayStart,
                dayEndExclusive: dayEndExclusive,
                dayKey: dayKey,
                dailyAggregate: aggregate,
                timelineEntries: timelineEntries,
                nutrition: nutrition,
                energyBalance: energyBalance,
                dataQuality: dataQuality,
                sourceCoverage: sourceCoverage
            )
        }
    }

    private static func loadDailyAggregate(
        db: Database,
        dayKey: String
    ) throws -> TodayDailyAggregateEvidence {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT computed_at, sleep_seconds, step_count, active_energy_kcal,
                       basal_energy_kcal, distance_m, exercise_minutes
                FROM activity_metrics_daily
                WHERE date = ?
                """,
            arguments: [dayKey]
        ) else {
            return .unavailable
        }

        let computedAt: Int64 = row["computed_at"]
        let asleepSeconds: Int? = row["sleep_seconds"]
        let steps: Int? = row["step_count"]
        let activeEnergyKcal: Double? = row["active_energy_kcal"]
        let basalEnergyKcal: Double? = row["basal_energy_kcal"]
        let distanceM: Double? = row["distance_m"]
        let exerciseMinutes: Double? = row["exercise_minutes"]

        return TodayDailyAggregateEvidence(
            wasComputed: true,
            computedAt: validatedDate(computedAt),
            asleepSeconds: validatedNonnegative(asleepSeconds),
            steps: validatedNonnegative(steps),
            activeEnergyKcal: MealNutritionProjection.validatedValue(activeEnergyKcal),
            basalEnergyKcal: MealNutritionProjection.validatedValue(basalEnergyKcal),
            distanceM: MealNutritionProjection.validatedValue(distanceM),
            exerciseMinutes: MealNutritionProjection.validatedValue(exerciseMinutes)
        )
    }

    private struct MealItemFacts {
        var itemCount = 0
        var provenanceKinds: [TodayMealProvenanceKind] = []
        var hasUserEditedItem = false
    }

    private static func loadMeals(
        db: Database,
        startEpoch: Int64,
        endEpoch: Int64
    ) throws -> [TodayMealEvidence] {
        let itemRows = try Row.fetchAll(
            db,
            sql: """
                SELECT i.meal_id, i.provenance_kind, i.is_user_edited
                FROM meal_items AS i
                JOIN meal_records AS m ON m.id = i.meal_id
                WHERE m.eaten_at >= ? AND m.eaten_at < ?
                ORDER BY i.meal_id ASC, i.sort_order ASC, i.id ASC
                """,
            arguments: [startEpoch, endEpoch]
        )
        var itemFactsByMealID: [Int64: MealItemFacts] = [:]
        for row in itemRows {
            let mealID: Int64 = row["meal_id"]
            let rawProvenance: String = row["provenance_kind"]
            let isUserEdited: Bool = row["is_user_edited"]
            guard let storedProvenance = MealItemRecord.ProvenanceKind(rawValue: rawProvenance) else {
                throw TodayEvidenceLoaderError.invalidMealProvenance(rawProvenance)
            }
            let provenance = TodayMealProvenanceKind(storedProvenance)
            var facts = itemFactsByMealID[mealID] ?? MealItemFacts()
            facts.itemCount += 1
            if !facts.provenanceKinds.contains(provenance) {
                facts.provenanceKinds.append(provenance)
            }
            facts.hasUserEditedItem = facts.hasUserEditedItem || isUserEdited
            itemFactsByMealID[mealID] = facts
        }

        let mealRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g
                FROM meal_records
                WHERE eaten_at >= ? AND eaten_at < ?
                ORDER BY eaten_at ASC, id ASC
                """,
            arguments: [startEpoch, endEpoch]
        )

        return try mealRows.map { row in
            let id: Int64 = row["id"]
            let rawMealType: String = row["meal_type"]
            let eatenAtEpoch: Int64 = row["eaten_at"]
            let caloriesKcal: Double? = row["calories_kcal"]
            let proteinG: Double? = row["protein_g"]
            let fatG: Double? = row["fat_g"]
            let carbsG: Double? = row["carbs_g"]
            guard let storedMealType = MealRecord.MealType(rawValue: rawMealType) else {
                throw TodayEvidenceLoaderError.invalidMealType(rawMealType)
            }
            let totals = MealNutritionProjection.project([
                MealNutritionValues(
                    caloriesKcal: caloriesKcal,
                    proteinG: proteinG,
                    fatG: fatG,
                    carbsG: carbsG
                )
            ])!
            let itemFacts = itemFactsByMealID[id] ?? MealItemFacts()
            let eatenAt = Date(timeIntervalSince1970: TimeInterval(eatenAtEpoch))

            return TodayMealEvidence(
                id: id,
                mealType: TodayMealKind(storedMealType),
                eatenAt: eatenAt,
                timelineAt: eatenAt,
                timeBasis: .eatenTime,
                totals: totals,
                itemCount: itemFacts.itemCount,
                provenanceKinds: itemFacts.provenanceKinds,
                hasUserEditedItem: itemFacts.hasUserEditedItem
            )
        }
    }

    private static func loadMedications(
        db: Database,
        startEpoch: Int64,
        endEpoch: Int64
    ) throws -> [TodayMedicationEvidence] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT l.id, l.plan_id, p.name AS plan_name, l.scheduled_at, l.action_at,
                       l.action, l.dosage_mg
                FROM medication_logs AS l
                LEFT JOIN medication_plans AS p ON p.id = l.plan_id
                WHERE COALESCE(l.action_at, l.scheduled_at) >= ?
                  AND COALESCE(l.action_at, l.scheduled_at) < ?
                ORDER BY COALESCE(l.action_at, l.scheduled_at) ASC, l.id ASC
                """,
            arguments: [startEpoch, endEpoch]
        )

        return try rows.map { row in
            let id: Int64 = row["id"]
            let planID: Int64? = row["plan_id"]
            let planName: String? = row["plan_name"]
            let scheduledAtEpoch: Int64 = row["scheduled_at"]
            let actionAtEpoch: Int64? = row["action_at"]
            let rawAction: String = row["action"]
            let dosageMg: Double? = row["dosage_mg"]
            guard let storedAction = MedicationLog.Action(rawValue: rawAction) else {
                throw TodayEvidenceLoaderError.invalidMedicationAction(rawAction)
            }

            let scheduledAt = Date(timeIntervalSince1970: TimeInterval(scheduledAtEpoch))
            let actionAt = actionAtEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return TodayMedicationEvidence(
                id: id,
                planID: planID,
                planName: planName,
                scheduledAt: scheduledAt,
                actionAt: actionAt,
                timelineAt: actionAt ?? scheduledAt,
                timeBasis: actionAt == nil ? .scheduledFallback : .actionTime,
                action: TodayMedicationAction(storedAction),
                dosageMg: MealNutritionProjection.validatedValue(dosageMg)
            )
        }
    }

    private static func sortedTimeline(
        _ entries: [TodayTimelineEvidenceEntry]
    ) -> [TodayTimelineEvidenceEntry] {
        entries.sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt {
                return lhs.timelineAt < rhs.timelineAt
            }
            if lhs.kindSortRank != rhs.kindSortRank {
                return lhs.kindSortRank < rhs.kindSortRank
            }
            return lhs.persistedID < rhs.persistedID
        }
    }

    private static func loadAlerts(
        db: Database,
        dayKey: String
    ) throws -> [TodayDataAlertEvidence] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, metric, severity, message, created_at
                FROM missing_data_alerts
                WHERE date = ? AND acknowledged = 0
                ORDER BY created_at ASC, id ASC
                """,
            arguments: [dayKey]
        )

        return try rows.map { row in
            let id: Int64 = row["id"]
            let metric: String = row["metric"]
            let rawSeverity: String = row["severity"]
            let message: String? = row["message"]
            let createdAt: Int64 = row["created_at"]
            guard let storedSeverity = MissingDataAlert.Severity(rawValue: rawSeverity) else {
                throw TodayEvidenceLoaderError.invalidAlertSeverity(rawSeverity)
            }
            return TodayDataAlertEvidence(
                id: id,
                metric: metric,
                severity: TodayDataAlertSeverity(storedSeverity),
                message: message,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt))
            )
        }
    }

    private static func loadDataQuality(
        db: Database,
        dayKey: String,
        alerts: [TodayDataAlertEvidence]
    ) throws -> TodayDataQualityEvidence {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT computed_at, completeness_score, freshness_score, conflict_score,
                       missing_metrics_json
                FROM data_quality_daily
                WHERE date = ?
                """,
            arguments: [dayKey]
        ) else {
            return TodayDataQualityEvidence(
                wasReconciled: false,
                computedAt: nil,
                completenessScore: nil,
                freshnessScore: nil,
                conflictScore: nil,
                missingMetricKeys: nil,
                alerts: alerts
            )
        }

        let computedAt: Int64 = row["computed_at"]
        let completenessScore: Double? = row["completeness_score"]
        let freshnessScore: Double? = row["freshness_score"]
        let conflictScore: Double? = row["conflict_score"]
        let missingMetricsJSON: String? = row["missing_metrics_json"]
        return TodayDataQualityEvidence(
            wasReconciled: true,
            computedAt: validatedDate(computedAt),
            completenessScore: validatedScore(completenessScore),
            freshnessScore: validatedScore(freshnessScore),
            conflictScore: validatedScore(conflictScore),
            missingMetricKeys: parseMissingMetricKeys(missingMetricsJSON),
            alerts: alerts
        )
    }

    private static func loadSourceCoverage(
        db: Database,
        startEpoch: Int64,
        endEpoch: Int64
    ) throws -> [TodaySourceCoverageEvidence] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT source_origin, source_name, COUNT(*) AS sample_count,
                       MAX(ingested_at) AS last_ingested_at
                FROM health_samples_raw INDEXED BY idx_raw_start
                WHERE start_at >= ? AND start_at < ? AND is_deleted = 0
                GROUP BY source_origin, source_name
                ORDER BY source_origin ASC, source_name ASC
                """,
            arguments: [startEpoch, endEpoch]
        )

        struct CoverageKey: Hashable {
            let origin: TodaySourceOrigin
            let sourceName: String?
        }
        struct CoverageAccumulator {
            var sampleCount = 0
            var lastIngestedAt: Date?
        }

        var coverageByKey: [CoverageKey: CoverageAccumulator] = [:]
        for row in rows {
            let rawOrigin: String? = row["source_origin"]
            let rawSourceName: String? = row["source_name"]
            let sourceName = normalizedSourceName(rawSourceName)
            let sampleCount: Int = row["sample_count"]
            let lastIngestedAt: Int64? = row["last_ingested_at"]
            let key = CoverageKey(
                origin: TodaySourceOrigin(rawValue: rawOrigin),
                sourceName: sourceName
            )
            var accumulated = coverageByKey[key] ?? CoverageAccumulator()
            accumulated.sampleCount += sampleCount
            if let candidate = lastIngestedAt.flatMap(validatedDate) {
                if let current = accumulated.lastIngestedAt {
                    accumulated.lastIngestedAt = max(current, candidate)
                } else {
                    accumulated.lastIngestedAt = candidate
                }
            }
            coverageByKey[key] = accumulated
        }

        return coverageByKey.map { key, value in
            TodaySourceCoverageEvidence(
                origin: key.origin,
                sourceName: key.sourceName,
                sampleCount: value.sampleCount,
                lastIngestedAt: value.lastIngestedAt
            )
        }.sorted { lhs, rhs in
            if lhs.origin.sortRank != rhs.origin.sortRank {
                return lhs.origin.sortRank < rhs.origin.sortRank
            }
            return (lhs.sourceName ?? "") < (rhs.sourceName ?? "")
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func validatedNonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func validatedDate(_ epoch: Int64) -> Date? {
        guard epoch >= 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    private static func validatedScore(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private static func normalizedSourceName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseMissingMetricKeys(_ rawJSON: String?) -> [String]? {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }

        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }
}
