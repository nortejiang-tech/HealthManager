import GRDB
import XCTest

@testable import HealthManager

final class TodayEvidenceLoaderTests: XCTestCase {
    func test01_successfulEmptyDayReturnsOnlyEmptyFacts() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: day, calendar: calendar)

        XCTAssertEqual(snapshot.dayStart, dayStart)
        XCTAssertEqual(snapshot.dayEndExclusive, dayEnd)
        XCTAssertEqual(snapshot.dayKey, "2026-07-14")
        XCTAssertFalse(snapshot.dailyAggregate.wasComputed)
        XCTAssertTrue(snapshot.timelineEntries.isEmpty)
        XCTAssertEqual(snapshot.nutrition, .empty)
        XCTAssertEqual(snapshot.energyBalance.intake, .noMeals)
        XCTAssertNil(snapshot.energyBalance.deficitKcal)
        XCTAssertFalse(snapshot.dataQuality.wasReconciled)
        XCTAssertNil(snapshot.dataQuality.missingMetricKeys)
        XCTAssertTrue(snapshot.dataQuality.alerts.isEmpty)
        XCTAssertTrue(snapshot.sourceCoverage.isEmpty)
    }

    func test02_localDayWindowIsHalfOpenAndCalendarBasedAcrossDST() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "America/Los_Angeles")
        let day = try XCTUnwrap(makeDate("2026-03-08 12:00:00", calendar: calendar))
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        XCTAssertEqual(dayEnd.timeIntervalSince(dayStart), 23 * 60 * 60)

        _ = try seedMeal(database, at: dayStart, mealType: .breakfast, calories: 200)
        _ = try seedMeal(database, at: dayEnd.addingTimeInterval(-1), mealType: .dinner, calories: 300)
        _ = try seedMeal(database, at: dayEnd, mealType: .snack, calories: 500)

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: day, calendar: calendar)

        XCTAssertEqual(snapshot.dayStart, dayStart)
        XCTAssertEqual(snapshot.dayEndExclusive, dayEnd)
        XCTAssertEqual(snapshot.timelineEntries.count, 2)
        XCTAssertEqual(snapshot.nutrition.mealCount, 2)
        XCTAssertEqual(snapshot.nutrition.calories, .complete(500))
    }

    func test03_timelineUsesStableOrderingAndPreservesEachTimeBasis() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let day = try XCTUnwrap(makeDate("2026-07-14 12:00:00", calendar: calendar))
        let dayStart = calendar.startOfDay(for: day)
        let ten = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: dayStart))
        let tenTen = try XCTUnwrap(calendar.date(byAdding: .minute, value: 10, to: ten))

        let firstMealID = try seedMeal(database, at: ten, mealType: .lunch, calories: 120)
        let secondMealID = try seedMeal(database, at: ten, mealType: .lunch, calories: 80)
        let actionID = try seedMedicationLog(
            database,
            planID: nil,
            scheduledAt: ten,
            action: .taken,
            actionAt: tenTen
        )
        let fallbackID = try seedMedicationLog(
            database,
            planID: nil,
            scheduledAt: ten,
            action: .skipped,
            actionAt: nil
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: day, calendar: calendar)

        XCTAssertEqual(
            snapshot.timelineEntries.map(\.id),
            ["meal-\(firstMealID)", "meal-\(secondMealID)", "medication-\(fallbackID)", "medication-\(actionID)"]
        )
        XCTAssertEqual(
            snapshot.timelineEntries.map(\.timeBasis),
            [.eatenTime, .eatenTime, .scheduledFallback, .actionTime]
        )
        XCTAssertEqual(snapshot.timelineEntries.map(\.timelineAt), [ten, ten, ten, tenTen])
    }

    func test04_parentAndDayNutritionUseConservativeSharedProjection() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let firstID = try seedMeal(
            database,
            at: dayStart.addingTimeInterval(8 * 60 * 60),
            mealType: .breakfast,
            calories: 0,
            protein: -1,
            fat: nil,
            carbs: 4
        )
        let secondID = try seedMeal(
            database,
            at: dayStart.addingTimeInterval(9 * 60 * 60),
            mealType: .snack,
            calories: .infinity,
            protein: 3,
            fat: 2,
            carbs: 4
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        let meals = mealEvidence(from: snapshot)
        let first = try XCTUnwrap(meals.first { $0.id == firstID })
        let second = try XCTUnwrap(meals.first { $0.id == secondID })

        XCTAssertEqual(first.totals.caloriesKcal, 0)
        XCTAssertNil(first.totals.proteinG)
        XCTAssertNil(first.totals.fatG)
        XCTAssertEqual(first.totals.carbsG, 4)
        XCTAssertNil(second.totals.caloriesKcal)
        XCTAssertEqual(second.totals.proteinG, 3)
        XCTAssertEqual(second.totals.fatG, 2)
        XCTAssertEqual(snapshot.nutrition.mealCount, 2)
        XCTAssertEqual(snapshot.nutrition.calories, .incomplete)
        XCTAssertNil(snapshot.nutrition.totals?.caloriesKcal)
        XCTAssertNil(snapshot.nutrition.totals?.proteinG)
        XCTAssertNil(snapshot.nutrition.totals?.fatG)
        XCTAssertEqual(snapshot.nutrition.totals?.carbsG, 8)
    }

    func test05_mealItemProvenanceIsStableDeduplicatedAndNeverInvented() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let itemMealID = try seedMeal(
            database,
            at: dayStart.addingTimeInterval(7 * 60 * 60),
            mealType: .breakfast,
            calories: 300
        )
        try seedMealItem(database, mealID: itemMealID, sortOrder: 0, provenance: .manual, isUserEdited: false)
        try seedMealItem(database, mealID: itemMealID, sortOrder: 1, provenance: .nutritionLabel, isUserEdited: true)
        try seedMealItem(database, mealID: itemMealID, sortOrder: 2, provenance: .manual, isUserEdited: false)
        let legacyMealID = try seedMeal(
            database,
            at: dayStart.addingTimeInterval(8 * 60 * 60),
            mealType: .lunch,
            calories: 150
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        let meals = mealEvidence(from: snapshot)
        let withItems = try XCTUnwrap(meals.first { $0.id == itemMealID })
        let legacy = try XCTUnwrap(meals.first { $0.id == legacyMealID })

        XCTAssertEqual(withItems.itemCount, 3)
        XCTAssertEqual(withItems.provenanceKinds, [.manual, .nutritionLabel])
        XCTAssertTrue(withItems.hasUserEditedItem)
        XCTAssertEqual(legacy.itemCount, 0)
        XCTAssertTrue(legacy.provenanceKinds.isEmpty)
        XCTAssertFalse(legacy.hasUserEditedItem)
    }

    func test06_medicationFactsUseActionFirstWithoutPlanDosageFallback() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let planID = try seedMedicationPlan(database, name: "周一注射", dosageMg: 12.5)

        let fallbackID = try seedMedicationLog(
            database,
            planID: planID,
            scheduledAt: dayStart,
            action: .deferred,
            dosageMg: nil
        )
        let takenID = try seedMedicationLog(
            database,
            planID: planID,
            scheduledAt: dayStart.addingTimeInterval(-60),
            action: .taken,
            actionAt: dayStart.addingTimeInterval(7 * 60 * 60),
            dosageMg: 0
        )
        let skippedID = try seedMedicationLog(
            database,
            planID: nil,
            scheduledAt: dayStart,
            action: .skipped,
            actionAt: dayStart.addingTimeInterval(8 * 60 * 60),
            dosageMg: -1
        )
        let lateFallbackID = try seedMedicationLog(
            database,
            planID: nil,
            scheduledAt: dayEnd.addingTimeInterval(-60),
            action: .taken,
            dosageMg: 9.9
        )
        let outsideID = try seedMedicationLog(
            database,
            planID: nil,
            scheduledAt: dayEnd.addingTimeInterval(-120),
            action: .taken,
            actionAt: dayEnd,
            dosageMg: 1
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        let medications = medicationEvidence(from: snapshot)

        XCTAssertEqual(Set(medications.map(\.id)), [fallbackID, takenID, skippedID, lateFallbackID])
        XCTAssertFalse(medications.contains { $0.id == outsideID })

        let fallback = try XCTUnwrap(medications.first { $0.id == fallbackID })
        XCTAssertEqual(fallback.planID, planID)
        XCTAssertEqual(fallback.planName, "周一注射")
        XCTAssertEqual(fallback.action, .deferred)
        XCTAssertEqual(fallback.timeBasis, .scheduledFallback)
        XCTAssertNil(fallback.actionAt)
        XCTAssertNil(fallback.dosageMg, "plan dosage must not be copied into an action log")

        let taken = try XCTUnwrap(medications.first { $0.id == takenID })
        XCTAssertEqual(taken.action, .taken)
        XCTAssertEqual(taken.timeBasis, .actionTime)
        XCTAssertEqual(taken.dosageMg, 0)

        let skipped = try XCTUnwrap(medications.first { $0.id == skippedID })
        XCTAssertEqual(skipped.action, .skipped)
        XCTAssertNil(skipped.planID)
        XCTAssertNil(skipped.planName)
        XCTAssertNil(skipped.dosageMg)

        let lateFallback = try XCTUnwrap(medications.first { $0.id == lateFallbackID })
        XCTAssertEqual(lateFallback.timelineAt, dayEnd.addingTimeInterval(-60))
        XCTAssertEqual(lateFallback.dosageMg, 9.9)
    }

    func test07_aggregateSeparatesMissingRowFromUnknownFieldsAndNeverBackfillsSleep() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: dayStart))

        let missing = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertFalse(missing.dailyAggregate.wasComputed)

        try seedActivityAggregate(
            database,
            on: previousDay,
            calendar: calendar,
            asleepSeconds: 3_600,
            steps: 1_000,
            activeEnergyKcal: 400,
            basalEnergyKcal: 800,
            distanceM: 1_200,
            exerciseMinutes: 10
        )
        try seedActivityAggregate(
            database,
            on: dayStart,
            calendar: calendar,
            asleepSeconds: nil,
            steps: 0,
            activeEnergyKcal: .infinity,
            basalEnergyKcal: -50,
            distanceM: 0,
            exerciseMinutes: .nan
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        let aggregate = snapshot.dailyAggregate

        XCTAssertTrue(aggregate.wasComputed)
        XCTAssertNil(aggregate.asleepSeconds, "previous-day sleep is not today's start_at bucket")
        XCTAssertEqual(aggregate.steps, 0)
        XCTAssertNil(aggregate.activeEnergyKcal)
        XCTAssertNil(aggregate.basalEnergyKcal)
        XCTAssertEqual(aggregate.distanceM, 0)
        XCTAssertNil(aggregate.exerciseMinutes)
        XCTAssertNotNil(aggregate.computedAt)
    }

    func test08_energyDeficitRequiresCompleteSameDayIntakeAndValidBurn() async throws {
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))

        let completeDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedActivityAggregate(
            completeDatabase,
            on: dayStart,
            calendar: calendar,
            activeEnergyKcal: 500,
            basalEnergyKcal: 1_500
        )
        _ = try seedMeal(
            completeDatabase,
            at: dayStart.addingTimeInterval(8 * 60 * 60),
            mealType: .breakfast,
            calories: 1_100
        )
        let complete = try await TodayEvidenceLoader(database: completeDatabase)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertEqual(complete.energyBalance.burnedKcal, 2_000)
        XCTAssertEqual(complete.energyBalance.intakeKcal, 1_100)
        XCTAssertEqual(complete.energyBalance.deficitKcal, 900)

        _ = try seedMeal(
            completeDatabase,
            at: dayStart.addingTimeInterval(10 * 60 * 60),
            mealType: .lunch,
            calories: nil
        )
        let incomplete = try await TodayEvidenceLoader(database: completeDatabase)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertEqual(incomplete.nutrition.calories, .incomplete)
        XCTAssertNil(incomplete.energyBalance.deficitKcal)

        let noMealsDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedActivityAggregate(
            noMealsDatabase,
            on: dayStart,
            calendar: calendar,
            activeEnergyKcal: 500,
            basalEnergyKcal: 1_500
        )
        let noMeals = try await TodayEvidenceLoader(database: noMealsDatabase)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertEqual(noMeals.energyBalance.intake, .noMeals)
        XCTAssertNil(noMeals.energyBalance.deficitKcal)

        let invalidBurnDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedActivityAggregate(
            invalidBurnDatabase,
            on: dayStart,
            calendar: calendar,
            activeEnergyKcal: -1,
            basalEnergyKcal: 1_500
        )
        _ = try seedMeal(invalidBurnDatabase, at: dayStart, mealType: .breakfast, calories: 1_100)
        let invalidBurn = try await TodayEvidenceLoader(database: invalidBurnDatabase)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertNil(invalidBurn.energyBalance.burnedKcal)
        XCTAssertNil(invalidBurn.energyBalance.deficitKcal)
    }

    func test09_qualityStatesAndScoresStayEvidenceBounded() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))

        let absent = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertFalse(absent.dataQuality.wasReconciled)
        XCTAssertNil(absent.dataQuality.missingMetricKeys)

        try seedDataQuality(
            database,
            on: dayStart,
            calendar: calendar,
            completenessScore: 0.8,
            freshnessScore: 0.9,
            conflictScore: 1.1,
            missingMetricsJSON: "[]"
        )
        let validEmpty = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertTrue(validEmpty.dataQuality.wasReconciled)
        XCTAssertEqual(validEmpty.dataQuality.completenessScore, 0.8)
        XCTAssertEqual(validEmpty.dataQuality.freshnessScore, 0.9)
        XCTAssertNil(validEmpty.dataQuality.conflictScore)
        XCTAssertEqual(validEmpty.dataQuality.missingMetricKeys, [])

        try seedDataQuality(
            database,
            on: dayStart,
            calendar: calendar,
            completenessScore: 1.2,
            freshnessScore: -0.2,
            conflictScore: .infinity,
            missingMetricsJSON: "[\" activeEnergy \" , \"activeEnergy\", \"\", \"sleep\"]"
        )
        let validKeys = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertNil(validKeys.dataQuality.completenessScore)
        XCTAssertNil(validKeys.dataQuality.freshnessScore)
        XCTAssertNil(validKeys.dataQuality.conflictScore)
        XCTAssertEqual(validKeys.dataQuality.missingMetricKeys, ["activeEnergy", "sleep"])

        try seedDataQuality(
            database,
            on: dayStart,
            calendar: calendar,
            missingMetricsJSON: "{bad-json"
        )
        let malformed = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        XCTAssertTrue(malformed.dataQuality.wasReconciled)
        XCTAssertNil(malformed.dataQuality.missingMetricKeys)
    }

    func test10_alertsOnlyIncludeCurrentUnacknowledgedFactsInStableOrder() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let currentKey = dayKey(for: dayStart, calendar: calendar)
        let previousKey = dayKey(
            for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: dayStart)),
            calendar: calendar
        )

        let firstID = try seedAlert(
            database,
            dayKey: currentKey,
            metric: "sleep",
            severity: .warning,
            message: "睡眠缺失",
            acknowledged: false,
            createdAt: 1_000
        )
        let secondID = try seedAlert(
            database,
            dayKey: currentKey,
            metric: "steps",
            severity: .critical,
            message: nil,
            acknowledged: false,
            createdAt: 1_000
        )
        _ = try seedAlert(
            database,
            dayKey: previousKey,
            metric: "sleep",
            severity: .info,
            message: "昨天",
            acknowledged: false,
            createdAt: 500
        )
        _ = try seedAlert(
            database,
            dayKey: currentKey,
            metric: "activeEnergy",
            severity: .warning,
            message: "已确认",
            acknowledged: true,
            createdAt: 900
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)
        let alerts = snapshot.dataQuality.alerts

        XCTAssertEqual(alerts.map(\.id), [firstID, secondID])
        XCTAssertEqual(alerts.map(\.metric), ["sleep", "steps"])
        XCTAssertEqual(alerts.map(\.severity), [.warning, .critical])
        XCTAssertEqual(alerts.map(\.message), ["睡眠缺失", nil])
        XCTAssertEqual(alerts.map(\.createdAt), [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_000)])
    }

    func test11_sourceCoverageUsesSampleStartWindowAndExcludesDeletedRows() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        let dayEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: dayStart))

        _ = try seedRawSample(
            database,
            startAt: dayStart,
            sourceOrigin: SourceAttribution.Origin.apple.rawValue,
            sourceName: "Apple Watch",
            ingestedAt: dayStart.addingTimeInterval(30)
        )
        _ = try seedRawSample(
            database,
            startAt: dayEnd.addingTimeInterval(-1),
            sourceOrigin: SourceAttribution.Origin.apple.rawValue,
            sourceName: "Apple Watch",
            ingestedAt: dayEnd.addingTimeInterval(120)
        )
        _ = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(60),
            sourceOrigin: "invalid-origin",
            sourceName: "Unknown Device",
            ingestedAt: dayEnd.addingTimeInterval(60)
        )
        _ = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(70),
            sourceOrigin: "another-invalid-origin",
            sourceName: "Unknown Device",
            ingestedAt: dayEnd.addingTimeInterval(90)
        )
        _ = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(80),
            sourceOrigin: nil,
            sourceName: "Unknown Device",
            ingestedAt: dayEnd.addingTimeInterval(100)
        )
        _ = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(90),
            sourceOrigin: SourceAttribution.Origin.manual.rawValue,
            sourceName: nil,
            ingestedAt: dayStart.addingTimeInterval(90)
        )
        _ = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(100),
            sourceOrigin: SourceAttribution.Origin.manual.rawValue,
            sourceName: "   ",
            ingestedAt: dayStart.addingTimeInterval(100)
        )
        let deletedUUID = try seedRawSample(
            database,
            startAt: dayStart.addingTimeInterval(120),
            sourceOrigin: SourceAttribution.Origin.apple.rawValue,
            sourceName: "Apple Watch",
            ingestedAt: dayStart.addingTimeInterval(120)
        )
        try markRawSampleDeleted(database, uuid: deletedUUID)
        _ = try seedRawSample(
            database,
            startAt: previousDay,
            sourceOrigin: SourceAttribution.Origin.apple.rawValue,
            sourceName: "Apple Watch",
            ingestedAt: dayStart.addingTimeInterval(40)
        )
        _ = try seedRawSample(
            database,
            startAt: dayEnd,
            sourceOrigin: SourceAttribution.Origin.apple.rawValue,
            sourceName: "Apple Watch",
            ingestedAt: dayEnd
        )

        let snapshot = try await TodayEvidenceLoader(database: database)
            .load(forLocalDay: dayStart, calendar: calendar)

        XCTAssertEqual(snapshot.sourceCoverage.count, 3)
        let apple = try XCTUnwrap(snapshot.sourceCoverage.first { $0.origin == .apple })
        XCTAssertEqual(apple.sourceName, "Apple Watch")
        XCTAssertEqual(apple.sampleCount, 2)
        XCTAssertEqual(apple.lastIngestedAt, dayEnd.addingTimeInterval(120))
        let manual = try XCTUnwrap(snapshot.sourceCoverage.first { $0.origin == .manual })
        XCTAssertNil(manual.sourceName)
        XCTAssertEqual(manual.sampleCount, 2)
        XCTAssertEqual(manual.lastIngestedAt, dayStart.addingTimeInterval(100))
        let unknown = try XCTUnwrap(snapshot.sourceCoverage.first { $0.origin == .unknown })
        XCTAssertEqual(unknown.sourceName, "Unknown Device")
        XCTAssertEqual(unknown.sampleCount, 3)
        XCTAssertEqual(unknown.lastIngestedAt, dayEnd.addingTimeInterval(100))
        XCTAssertEqual(snapshot.sourceCoverage.map(\.origin), [.apple, .manual, .unknown])
    }

    func test12_requiredReadFailureThrowsInsteadOfReturningEmptySuccess() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = makeCalendar(timeZoneIdentifier: "Asia/Shanghai")
        let dayStart = try XCTUnwrap(makeDate("2026-07-14 00:00:00", calendar: calendar))
        try database.write { db in
            try db.execute(sql: "DROP TABLE meal_records")
        }

        do {
            _ = try await TodayEvidenceLoader(database: database)
                .load(forLocalDay: dayStart, calendar: calendar)
            XCTFail("a required table failure must propagate")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    private func mealEvidence(from snapshot: TodayEvidenceSnapshot) -> [TodayMealEvidence] {
        snapshot.timelineEntries.compactMap { entry in
            guard case let .meal(value) = entry else { return nil }
            return value
        }
    }

    private func medicationEvidence(from snapshot: TodayEvidenceSnapshot) -> [TodayMedicationEvidence] {
        snapshot.timelineEntries.compactMap { entry in
            guard case let .medication(value) = entry else { return nil }
            return value
        }
    }

    private func makeCalendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
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

    private func dayKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @discardableResult
    private func seedMeal(
        _ database: DatabaseManager,
        at date: Date,
        mealType: MealRecord.MealType,
        calories: Double?,
        protein: Double? = 0,
        fat: Double? = 0,
        carbs: Double? = 0
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_records
                      (meal_type, eaten_at, calories_kcal, protein_g, fat_g, carbs_g, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    mealType.rawValue,
                    Int64(date.timeIntervalSince1970),
                    calories,
                    protein,
                    fat,
                    carbs,
                    Int64(date.timeIntervalSince1970)
                ]
            )
            return db.lastInsertedRowID
        }
    }

    private func seedMealItem(
        _ database: DatabaseManager,
        mealID: Int64,
        sortOrder: Int,
        provenance: MealItemRecord.ProvenanceKind,
        isUserEdited: Bool
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meal_items
                      (meal_id, sort_order, name, preparation_state, calories_kcal, grams,
                       protein_g, fat_g, carbs_g, provenance_kind, is_user_edited, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    mealID,
                    sortOrder,
                    "item-\(sortOrder)",
                    MealItemRecord.PreparationState.unknown.rawValue,
                    0,
                    nil,
                    0,
                    0,
                    0,
                    provenance.rawValue,
                    isUserEdited,
                    1_000 + sortOrder,
                    1_000 + sortOrder
                ]
            )
        }
    }

    @discardableResult
    private func seedMedicationPlan(
        _ database: DatabaseManager,
        name: String,
        dosageMg: Double?
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO medication_plans (name, dosage_mg, reminder_enabled, created_at)
                    VALUES (?, ?, 1, 1000)
                    """,
                arguments: [name, dosageMg]
            )
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    private func seedMedicationLog(
        _ database: DatabaseManager,
        planID: Int64?,
        scheduledAt: Date,
        action: MedicationLog.Action,
        actionAt: Date? = nil,
        dosageMg: Double? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO medication_logs
                      (plan_id, scheduled_at, action, action_at, dosage_mg, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    planID,
                    Int64(scheduledAt.timeIntervalSince1970),
                    action.rawValue,
                    actionAt.map { Int64($0.timeIntervalSince1970) },
                    dosageMg,
                    Int64(scheduledAt.timeIntervalSince1970)
                ]
            )
            return db.lastInsertedRowID
        }
    }

    private func seedActivityAggregate(
        _ database: DatabaseManager,
        on day: Date,
        calendar: Calendar,
        asleepSeconds: Int? = nil,
        steps: Int? = nil,
        activeEnergyKcal: Double? = nil,
        basalEnergyKcal: Double? = nil,
        distanceM: Double? = nil,
        exerciseMinutes: Double? = nil
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO activity_metrics_daily
                      (date, sleep_seconds, step_count, active_energy_kcal, basal_energy_kcal,
                       distance_m, exercise_minutes, computed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1000)
                    """,
                arguments: [
                    dayKey(for: day, calendar: calendar),
                    asleepSeconds,
                    steps,
                    activeEnergyKcal,
                    basalEnergyKcal,
                    distanceM,
                    exerciseMinutes
                ]
            )
        }
    }

    private func seedDataQuality(
        _ database: DatabaseManager,
        on day: Date,
        calendar: Calendar,
        completenessScore: Double? = nil,
        freshnessScore: Double? = nil,
        conflictScore: Double? = nil,
        missingMetricsJSON: String?
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO data_quality_daily
                      (date, completeness_score, freshness_score, conflict_score, missing_metrics_json, computed_at)
                    VALUES (?, ?, ?, ?, ?, 1000)
                    ON CONFLICT(date) DO UPDATE SET
                      completeness_score = excluded.completeness_score,
                      freshness_score = excluded.freshness_score,
                      conflict_score = excluded.conflict_score,
                      missing_metrics_json = excluded.missing_metrics_json,
                      computed_at = excluded.computed_at
                    """,
                arguments: [
                    dayKey(for: day, calendar: calendar),
                    completenessScore,
                    freshnessScore,
                    conflictScore,
                    missingMetricsJSON
                ]
            )
        }
    }

    @discardableResult
    private func seedAlert(
        _ database: DatabaseManager,
        dayKey: String,
        metric: String,
        severity: MissingDataAlert.Severity,
        message: String?,
        acknowledged: Bool,
        createdAt: Int64
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO missing_data_alerts
                      (date, metric, severity, message, acknowledged, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [dayKey, metric, severity.rawValue, message, acknowledged, createdAt]
            )
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    private func seedRawSample(
        _ database: DatabaseManager,
        startAt: Date,
        sourceOrigin: String?,
        sourceName: String?,
        ingestedAt: Date
    ) throws -> String {
        let uuid = UUID().uuidString
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at, source_name,
                       source_bundle_id, ingested_at, is_deleted, source_origin)
                    VALUES (?, 'HKQuantityTypeIdentifierStepCount', 'quantity', 1, 'count',
                            ?, ?, ?, NULL, ?, 0, ?)
                    """,
                arguments: [
                    uuid,
                    Int64(startAt.timeIntervalSince1970),
                    Int64(startAt.addingTimeInterval(1).timeIntervalSince1970),
                    sourceName,
                    Int64(ingestedAt.timeIntervalSince1970),
                    sourceOrigin
                ]
            )
        }
        return uuid
    }

    private func markRawSampleDeleted(_ database: DatabaseManager, uuid: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE health_samples_raw SET is_deleted = 1 WHERE sample_uuid = ?",
                arguments: [uuid]
            )
        }
    }
}
