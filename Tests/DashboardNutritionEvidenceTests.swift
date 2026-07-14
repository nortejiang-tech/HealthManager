import XCTest
import GRDB

@testable import HealthManager

final class DashboardNutritionEvidenceTests: XCTestCase {
    func test_queryEmptyWindowReturnsNoMealEvidence() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: day,
                throughLocalDay: day,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.mealCount, 0)
        XCTAssertNil(evidence.totals)
        XCTAssertEqual(evidence.calories, .noMeals)
        XCTAssertTrue(evidence.days.isEmpty)
    }

    func test_queryReturnsCompleteWindowAndOrderedDayEvidenceIncludingKnownZero() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let firstDay = try XCTUnwrap(makeDate("2026-07-13 12:00:00", calendar: calendar))
        let secondDay = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))

        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-13 08:00:00", calendar: calendar)),
            calories: 120,
            protein: 8,
            fat: 4,
            carbs: 12
        )
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-14 08:00:00", calendar: calendar)),
            calories: 0,
            protein: 0,
            fat: 0,
            carbs: 0
        )

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: firstDay,
                throughLocalDay: secondDay,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.mealCount, 2)
        XCTAssertEqual(evidence.calories, .complete(120))
        XCTAssertEqual(evidence.totals?.proteinG, 8)
        XCTAssertEqual(evidence.days.map(\.date), [
            calendar.startOfDay(for: firstDay),
            calendar.startOfDay(for: secondDay)
        ])
        XCTAssertEqual(evidence.days.map(\.calories), [.complete(120), .complete(0)])
    }

    func test_queryMarksNegativeOrMissingCaloriesIncompleteWithoutPollutingProtein() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))

        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-14 08:00:00", calendar: calendar)),
            calories: 120,
            protein: 8,
            fat: 4,
            carbs: 12
        )
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-14 13:00:00", calendar: calendar)),
            calories: -20,
            protein: 2,
            fat: 1,
            carbs: 3
        )

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: day,
                throughLocalDay: day,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.calories, .incomplete)
        XCTAssertNil(evidence.totals?.caloriesKcal)
        XCTAssertEqual(evidence.totals?.proteinG, 10)
        XCTAssertEqual(evidence.days.first?.calories, .incomplete)
    }

    func test_queryRejectsPersistedNegativeMacrosIndependentlyFromValidCalories() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-14 08:00:00", calendar: calendar)),
            calories: 100,
            protein: -1,
            fat: -2,
            carbs: -3
        )

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: day,
                throughLocalDay: day,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.calories, .complete(100))
        XCTAssertEqual(evidence.totals?.caloriesKcal, 100)
        XCTAssertNil(evidence.totals?.proteinG)
        XCTAssertNil(evidence.totals?.fatG)
        XCTAssertNil(evidence.totals?.carbsG)
        XCTAssertNil(evidence.days.first?.totals.proteinG)
        XCTAssertNil(evidence.days.first?.totals.fatG)
        XCTAssertNil(evidence.days.first?.totals.carbsG)
    }

    func test_queryUsesCalendarNextStartAcrossDST() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "America/Los_Angeles")
        let springForwardDay = try XCTUnwrap(makeDate("2026-03-08 12:00:00", calendar: calendar))

        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-03-08 00:00:00", calendar: calendar)),
            calories: 100
        )
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-03-08 23:59:59", calendar: calendar)),
            calories: 200
        )
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-03-09 00:00:00", calendar: calendar)),
            calories: 999
        )

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: springForwardDay,
                throughLocalDay: springForwardDay,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.mealCount, 2)
        XCTAssertEqual(evidence.calories, .complete(300))
        XCTAssertEqual(evidence.days.count, 1)
    }

    func test_energyBalanceComputesOnlyFromCompleteKnownInputs() {
        let evidence = EnergyBalanceEvidence(
            activeKcal: 500,
            basalKcal: 1_500,
            intake: .complete(1_100)
        )

        XCTAssertEqual(evidence.burnedKcal, 2_000)
        XCTAssertEqual(evidence.intakeKcal, 1_100)
        XCTAssertEqual(evidence.deficitKcal, 900)
    }

    func test_energyBalanceRejectsMissingInvalidAndOverflowingInputs() {
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: nil,
            basalKcal: 1_500,
            intake: .complete(1_100)
        ).deficitKcal)
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: -1,
            basalKcal: 1_500,
            intake: .complete(1_100)
        ).burnedKcal)
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: 500,
            basalKcal: .infinity,
            intake: .complete(1_100)
        ).burnedKcal)
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: .greatestFiniteMagnitude,
            basalKcal: .greatestFiniteMagnitude,
            intake: .complete(0)
        ).burnedKcal)
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: 500,
            basalKcal: 1_500,
            intake: .noMeals
        ).deficitKcal)
        XCTAssertNil(EnergyBalanceEvidence(
            activeKcal: 500,
            basalKcal: 1_500,
            intake: .incomplete
        ).deficitKcal)
    }

    func test_energyBalancePreservesKnownZeroAndNegativeDeficit() {
        let zero = EnergyBalanceEvidence(
            activeKcal: 0,
            basalKcal: 0,
            intake: .complete(0)
        )
        XCTAssertEqual(zero.burnedKcal, 0)
        XCTAssertEqual(zero.deficitKcal, 0)

        let surplus = EnergyBalanceEvidence(
            activeKcal: 100,
            basalKcal: 1_400,
            intake: .complete(1_800)
        )
        XCTAssertEqual(surplus.deficitKcal, -300)
    }

    func test_dashboardSnapshotKeepsIncompleteMealUnknownAndSuppressesDeficit() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: 120,
            protein: 8,
            fat: 4,
            carbs: 12
        )
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 13, to: today)!,
            calories: nil,
            protein: 2,
            fat: 1,
            carbs: 3
        )
        try seedActivity(database, on: today, active: 500, basal: 1_500)

        let snapshot = try await DashboardLoader(database: database).loadSnapshot()

        XCTAssertNil(snapshot.diet.totals?.caloriesKcal)
        XCTAssertEqual(snapshot.diet.totals?.proteinG, 10)
        XCTAssertEqual(snapshot.diet.meals.map(\.kcal), [120, nil])
        XCTAssertTrue(snapshot.diet.hasIncompleteCalorieDays)
        XCTAssertEqual(snapshot.deficit.energy.intake, .incomplete)
        XCTAssertNil(snapshot.deficit.todayIntake)
        XCTAssertNil(snapshot.deficit.todayDeficit)
    }

    func test_dashboardSnapshotRejectsPersistedNegativeNutritionValues() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: -1,
            protein: -2,
            fat: -3,
            carbs: -4
        )
        try seedActivity(database, on: today, active: 500, basal: 1_500)

        let snapshot = try await DashboardLoader(database: database).loadSnapshot()

        XCTAssertNil(snapshot.diet.todayCalories)
        XCTAssertNil(snapshot.diet.todayProtein)
        XCTAssertNil(snapshot.diet.todayFat)
        XCTAssertNil(snapshot.diet.todayCarbs)
        XCTAssertNil(snapshot.diet.meals.first?.kcal)
        XCTAssertTrue(snapshot.diet.hasIncompleteCalorieDays)
        XCTAssertEqual(snapshot.deficit.energy.intake, .incomplete)
        XCTAssertNil(snapshot.deficit.todayDeficit)
    }

    func test_dashboardSnapshotDoesNotTreatNoMealsAsZeroIntake() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let today = Calendar.current.startOfDay(for: Date())
        try seedActivity(database, on: today, active: 500, basal: 1_500)

        let snapshot = try await DashboardLoader(database: database).loadSnapshot()

        XCTAssertNil(snapshot.diet.totals)
        XCTAssertEqual(snapshot.deficit.energy.intake, .noMeals)
        XCTAssertEqual(snapshot.deficit.todayBurned, 2_000)
        XCTAssertNil(snapshot.deficit.todayIntake)
        XCTAssertNil(snapshot.deficit.todayDeficit)
    }

    func test_dashboardSnapshotPreservesCompleteKnownZero() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: 0,
            protein: 0,
            fat: 0,
            carbs: 0
        )
        try seedActivity(database, on: today, active: 0, basal: 0)

        let snapshot = try await DashboardLoader(database: database).loadSnapshot()

        XCTAssertEqual(snapshot.diet.todayCalories, 0)
        XCTAssertEqual(snapshot.deficit.todayBurned, 0)
        XCTAssertEqual(snapshot.deficit.todayIntake, 0)
        XCTAssertEqual(snapshot.deficit.todayDeficit, 0)
    }

    func test_dietSeriesKeepsIncompleteDayAsGapAndCompleteZeroAsPoint() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: yesterday)!,
            calories: -1
        )
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: 0
        )

        let points = try await DashboardLoader(database: database).loadDietSeries(period: .week)

        XCTAssertNil(point(on: yesterday, in: points)?.value)
        XCTAssertEqual(point(on: today, in: points)?.value, 0)
    }

    func test_deficitSeriesOnlyEmitsCompleteEnergyAndIntakeIntersection() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        try seedActivity(database, on: yesterday, active: 500, basal: 1_500)
        try seedActivity(database, on: today, active: 500, basal: 1_500)
        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: 1_100
        )

        let points = try await DashboardLoader(database: database).loadDeficitSeries(period: .week)

        XCTAssertNil(point(on: yesterday, in: points)?.value)
        XCTAssertEqual(point(on: today, in: points)?.value, 900)
    }

    func test_deficitBreakdownDistinguishesNoMealsFromIncompleteIntake() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try seedActivity(database, on: today, active: 500, basal: 1_500)
        let loader = DashboardLoader(database: database)

        let noMeals = try await loader.loadDeficitBreakdown(for: today)
        XCTAssertEqual(noMeals?.intakeEvidence, .noMeals)
        XCTAssertNil(noMeals?.deficit)

        try seedMeal(
            database,
            at: calendar.date(byAdding: .hour, value: 8, to: today)!,
            calories: -1
        )
        let incomplete = try await loader.loadDeficitBreakdown(for: today)
        XCTAssertEqual(incomplete?.intakeEvidence, .incomplete)
        XCTAssertNil(incomplete?.deficit)
    }

    func test_activityDetailSummaryUsesSharedEnergyEvidence() {
        var summary = ActivityDetailSummary()
        summary.activeEnergyKcal = 500
        summary.basalEnergyKcal = 1_500
        XCTAssertNil(summary.deficitKcal)

        summary.intakeEvidence = .incomplete
        XCTAssertNil(summary.deficitKcal)

        summary.intakeEvidence = .complete(1_100)
        XCTAssertEqual(summary.totalBurnedKcal, 2_000)
        XCTAssertEqual(summary.intakeKcal, 1_100)
        XCTAssertEqual(summary.deficitKcal, 900)

        summary.activeEnergyKcal = nil
        XCTAssertNil(summary.totalBurnedKcal)
        XCTAssertNil(summary.deficitKcal)
    }

    func test_queryTreatsPersistedInfinityAsIncompleteWhenSQLiteRoundTripsIt() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))
        try seedMeal(
            database,
            at: try XCTUnwrap(makeDate("2026-07-14 08:00:00", calendar: calendar)),
            calories: .infinity
        )

        let evidence = try database.read { db in
            try MealNutritionEvidenceQuery.load(
                db: db,
                fromLocalDay: day,
                throughLocalDay: day,
                calendar: calendar
            )
        }

        XCTAssertEqual(evidence.calories, .incomplete)
    }

    private func makeCalendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func makeDate(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func seedMeal(
        _ database: DatabaseManager,
        at date: Date,
        calories: Double?,
        protein: Double? = 0,
        fat: Double? = 0,
        carbs: Double? = 0
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_records
                      (meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g, created_at)
                    VALUES ('meal', ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Int64(date.timeIntervalSince1970),
                    calories,
                    protein,
                    fat,
                    carbs,
                    Int64(date.timeIntervalSince1970)
                ]
            )
        }
    }

    private func seedActivity(
        _ database: DatabaseManager,
        on date: Date,
        active: Double?,
        basal: Double?
    ) throws {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO activity_metrics_daily
                      (date, active_energy_kcal, basal_energy_kcal, computed_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    formatter.string(from: date),
                    active,
                    basal,
                    Int64(date.timeIntervalSince1970)
                ]
            )
        }
    }

    private func point(on date: Date, in points: [MetricPoint]) -> MetricPoint? {
        points.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }
}
