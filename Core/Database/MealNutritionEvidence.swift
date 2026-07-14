import Foundation
import GRDB

enum DietCaloriesEvidence: Equatable, Sendable {
    case noMeals
    case incomplete
    case complete(Double)

    var value: Double? {
        guard case let .complete(value) = self else { return nil }
        return value
    }
}

struct EnergyBalanceEvidence: Equatable, Sendable {
    let activeKcal: Double?
    let basalKcal: Double?
    let intake: DietCaloriesEvidence

    init(activeKcal: Double?, basalKcal: Double?, intake: DietCaloriesEvidence) {
        self.activeKcal = MealNutritionProjection.validatedValue(activeKcal)
        self.basalKcal = MealNutritionProjection.validatedValue(basalKcal)
        switch intake {
        case let .complete(value):
            self.intake = MealNutritionProjection.validatedValue(value).map {
                .complete($0)
            } ?? .incomplete
        case .noMeals:
            self.intake = .noMeals
        case .incomplete:
            self.intake = .incomplete
        }
    }

    var burnedKcal: Double? {
        guard let activeKcal, let basalKcal else { return nil }
        let value = activeKcal + basalKcal
        return value.isFinite ? value : nil
    }

    var intakeKcal: Double? {
        intake.value
    }

    var deficitKcal: Double? {
        guard let burnedKcal, let intakeKcal else { return nil }
        let value = burnedKcal - intakeKcal
        return value.isFinite ? value : nil
    }
}

struct MealNutritionDayEvidence: Equatable, Sendable {
    let date: Date
    let mealCount: Int
    let totals: MealNutritionTotals
    let calories: DietCaloriesEvidence
}

struct MealNutritionEvidenceWindow: Equatable, Sendable {
    let mealCount: Int
    let totals: MealNutritionTotals?
    let calories: DietCaloriesEvidence
    let days: [MealNutritionDayEvidence]

    static let empty = MealNutritionEvidenceWindow(
        mealCount: 0,
        totals: nil,
        calories: .noMeals,
        days: []
    )
}

enum MealNutritionEvidenceQuery {
    enum QueryError: Error, Equatable {
        case invalidLocalDayWindow
    }

    static func load(
        db: Database,
        fromLocalDay: Date,
        throughLocalDay: Date,
        calendar: Calendar = .current
    ) throws -> MealNutritionEvidenceWindow {
        let start = calendar.startOfDay(for: fromLocalDay)
        let finalDay = calendar.startOfDay(for: throughLocalDay)
        guard finalDay >= start,
              let endExclusive = calendar.date(byAdding: .day, value: 1, to: finalDay)
        else {
            throw QueryError.invalidLocalDayWindow
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT eaten_at, calories_kcal, protein_g, fat_g, carbs_g
                FROM meal_records
                WHERE eaten_at >= ? AND eaten_at < ?
                ORDER BY eaten_at ASC
                """,
            arguments: [
                Int64(start.timeIntervalSince1970),
                Int64(endExclusive.timeIntervalSince1970)
            ]
        )

        let entries: [(date: Date, values: MealNutritionValues)] = rows.map { row in
            let epoch: Int64 = row["eaten_at"]
            return (
                Date(timeIntervalSince1970: TimeInterval(epoch)),
                MealNutritionValues(
                    caloriesKcal: row["calories_kcal"],
                    proteinG: row["protein_g"],
                    fatG: row["fat_g"],
                    carbsG: row["carbs_g"]
                )
            )
        }
        let totals = MealNutritionProjection.project(entries.map(\.values))

        let grouped = Dictionary(grouping: entries) {
            calendar.startOfDay(for: $0.date)
        }
        let days = grouped.keys.sorted().compactMap { day -> MealNutritionDayEvidence? in
            guard let values = grouped[day]?.map(\.values),
                  let dayTotals = MealNutritionProjection.project(values)
            else {
                return nil
            }
            return MealNutritionDayEvidence(
                date: day,
                mealCount: values.count,
                totals: dayTotals,
                calories: caloriesEvidence(mealCount: values.count, totals: dayTotals)
            )
        }

        return MealNutritionEvidenceWindow(
            mealCount: entries.count,
            totals: totals,
            calories: caloriesEvidence(mealCount: entries.count, totals: totals),
            days: days
        )
    }

    private static func caloriesEvidence(
        mealCount: Int,
        totals: MealNutritionTotals?
    ) -> DietCaloriesEvidence {
        guard mealCount > 0 else { return .noMeals }
        guard let calories = totals?.caloriesKcal else { return .incomplete }
        return .complete(calories)
    }
}
