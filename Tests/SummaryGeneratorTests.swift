import XCTest
import GRDB
@testable import HealthManager

/// SummaryGenerator dominant-source dedup: cumulative metrics (step count) written by
/// multiple sources for the same day must not be cross-source summed; the report should
/// pick the highest-priority source and report only its sum.
final class SummaryGeneratorTests: XCTestCase {

    func test_stepCount_dedup_prefersGarminOverApple() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = f.string(from: dayStart)

        // Garmin: 10,000 steps in 4 chunks
        // Apple Health: 8,000 steps in 4 chunks
        // Naive SUM would yield 18,000; dominant-source picks Garmin and reports 10,000.
        try db.write { db in
            for (i, chunk) in [2500, 2500, 2500, 2500].enumerated() {
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted)
                    VALUES (?, ?, 'quantity', ?, 'count', ?, ?, 'Garmin Connect', 'com.garmin.connect.mobile', ?, 0)
                    """, arguments: [
                        UUID().uuidString,
                        "HKQuantityTypeIdentifierStepCount",
                        Double(chunk),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600 + 60),
                        Int64(Date().timeIntervalSince1970)
                    ])
            }
            for (i, chunk) in [2000, 2000, 2000, 2000].enumerated() {
                try db.execute(sql: """
                    INSERT INTO health_samples_raw
                      (sample_uuid, hk_type, kind, value, unit, start_at, end_at,
                       source_name, source_bundle_id, ingested_at, is_deleted)
                    VALUES (?, ?, 'quantity', ?, 'count', ?, ?, 'iPhone', 'com.apple.Health', ?, 0)
                    """, arguments: [
                        UUID().uuidString,
                        "HKQuantityTypeIdentifierStepCount",
                        Double(chunk),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600),
                        Int64(dayStart.timeIntervalSince1970) + Int64(i * 3600 + 60),
                        Int64(Date().timeIntervalSince1970)
                    ])
            }
        }

        let gen = SummaryGenerator(database: db)
        let summary = try await gen.generateDaily(for: todayKey)

        guard let text = summary.summaryText else {
            return XCTFail("daily summary text was nil")
        }
        XCTAssertTrue(
            text.contains("10000") || text.contains("10,000"),
            "summary should report Garmin's 10000 steps, got: \(text)"
        )
        XCTAssertFalse(text.contains("18000"), "must not cross-source sum")
    }

    func test_emptyDay_summaryIsNonEmpty() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let gen = SummaryGenerator(database: db)
        let summary = try await gen.generateDaily(for: "2025-01-01")
        XCTAssertNotNil(summary.summaryText)
        XCTAssertFalse(summary.summaryText?.isEmpty ?? true)
    }

    func test_dailySummaryReportsIncompleteCaloriesWithoutFalseNumericFinding() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        try seedMeal(db, at: day.addingTimeInterval(8 * 3_600), calories: 120, protein: 8)
        try seedMeal(db, at: day.addingTimeInterval(13 * 3_600), calories: nil, protein: 2)

        let summary = try await SummaryGenerator(database: db).generateDaily(for: "2026-07-14")
        let text = try XCTUnwrap(summary.summaryText)
        let findings = try jsonObject(summary.keyFindingsJson)

        XCTAssertTrue(text.contains("2 餐"))
        XCTAssertTrue(text.contains("热量记录不完整"))
        XCTAssertTrue(text.contains("蛋白 10 g"))
        XCTAssertFalse(text.contains("摄入 120 kcal"))
        XCTAssertEqual(findings["mealCount"] as? Int, 2)
        XCTAssertNil(findings["caloriesIn"])
        XCTAssertEqual(findings["caloriesInStatus"] as? String, "incomplete")
    }

    func test_weeklySummarySuppressesNumericIntakeWhenAnyMealIsIncomplete() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let weekStart = try XCTUnwrap(date("2026-07-13 00:00:00", calendar: calendar))
        try seedMeal(db, at: weekStart.addingTimeInterval(8 * 3_600), calories: 120)
        try seedMeal(db, at: weekStart.addingTimeInterval(32 * 3_600), calories: nil)

        let summary = try await SummaryGenerator(database: db).generateWeekly(weekStart: "2026-07-13")
        let text = try XCTUnwrap(summary.summaryText)
        let findings = try jsonObject(summary.findingsJson)

        XCTAssertTrue(text.contains("2 餐"))
        XCTAssertTrue(text.contains("热量记录不完整"))
        XCTAssertFalse(text.contains("摄入 120 kcal"))
        XCTAssertEqual(findings["mealCount"] as? Int, 2)
        XCTAssertNil(findings["caloriesIn"])
        XCTAssertEqual(findings["caloriesInStatus"] as? String, "incomplete")
    }

    func test_currentDailyRegeneratesLegacySummaryAndClearsOldLLMCommentary() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        try seedMeal(db, at: day.addingTimeInterval(8 * 3_600), calories: nil, protein: 8)
        try db.write { database in
            try DailySummary(
                date: "2026-07-14",
                summaryText: "旧总结：摄入 0 kcal",
                keyFindingsJson: #"{"caloriesIn":0}"#,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 评注",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
        }

        let current = try await SummaryGenerator(database: db).currentDaily(for: "2026-07-14")
        let summary = try XCTUnwrap(current)
        let findings = try jsonObject(summary.keyFindingsJson)

        XCTAssertTrue(summary.summaryText?.contains("热量记录不完整") == true)
        XCTAssertEqual(
            findings[SummaryGenerator.nutritionEvidenceContractKey] as? Int,
            SummaryGenerator.nutritionEvidenceContractVersion
        )
        XCTAssertNil(summary.llmText)
        XCTAssertNil(summary.llmModel)
        XCTAssertNil(summary.llmGeneratedAt)
    }

    func test_currentWeeklyRegeneratesLegacySummaryAndClearsOldLLMCommentary() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let weekStart = try XCTUnwrap(date("2026-07-13 00:00:00", calendar: calendar))
        try seedMeal(db, at: weekStart.addingTimeInterval(8 * 3_600), calories: nil)
        try db.write { database in
            try WeeklySummary(
                weekStartDate: "2026-07-13",
                summaryText: "旧周报：摄入 0 kcal",
                findingsJson: #"{"caloriesIn":0}"#,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 周评",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
        }

        let current = try await SummaryGenerator(database: db)
            .currentWeekly(weekStart: "2026-07-13")
        let summary = try XCTUnwrap(current)
        let findings = try jsonObject(summary.findingsJson)

        XCTAssertTrue(summary.summaryText?.contains("热量记录不完整") == true)
        XCTAssertEqual(
            findings[SummaryGenerator.nutritionEvidenceContractKey] as? Int,
            SummaryGenerator.nutritionEvidenceContractVersion
        )
        XCTAssertNil(summary.llmText)
        XCTAssertNil(summary.llmModel)
        XCTAssertNil(summary.llmGeneratedAt)
    }

    func test_currentReadersDoNotCreateSummariesWhenNothingWasGenerated() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let generator = SummaryGenerator(database: db)

        let daily = try await generator.currentDaily(for: "2026-07-14")
        let weekly = try await generator.currentWeekly(weekStart: "2026-07-13")
        let storedCounts = try db.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM daily_summaries") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM weekly_summaries") ?? 0
            )
        }

        XCTAssertNil(daily)
        XCTAssertNil(weekly)
        XCTAssertEqual(storedCounts.0, 0)
        XCTAssertEqual(storedCounts.1, 0)
    }

    func test_rebuildDailyForLLMAlwaysPersistsTrustedTextAndInvalidatesOldCommentary() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        try seedMeal(db, at: day.addingTimeInterval(8 * 3_600), calories: 100)
        let currentMarker = """
            {"\(SummaryGenerator.nutritionEvidenceContractKey)":\(SummaryGenerator.nutritionEvidenceContractVersion)}
            """
        try db.write { database in
            try DailySummary(
                date: "2026-07-14",
                summaryText: "已过时但带当前标记：摄入 0 kcal",
                keyFindingsJson: currentMarker,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 评注",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
        }

        let text = try await SummaryGenerator(database: db).rebuildDailyForLLM(for: "2026-07-14")
        let stored = try db.read { database in
            try DailySummary.fetchOne(database, key: "2026-07-14")
        }

        XCTAssertTrue(text?.contains("摄入 100 kcal") == true)
        XCTAssertFalse(text?.contains("摄入 0 kcal") == true)
        XCTAssertNil(stored?.llmText)
        XCTAssertNil(stored?.llmModel)
        XCTAssertNil(stored?.llmGeneratedAt)
    }

    func test_rebuildWeeklyForLLMAlwaysPersistsTrustedTextAndInvalidatesOldCommentary() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let weekStart = try XCTUnwrap(date("2026-07-13 00:00:00", calendar: calendar))
        try seedMeal(db, at: weekStart.addingTimeInterval(8 * 3_600), calories: 100)
        let currentMarker = """
            {"\(SummaryGenerator.nutritionEvidenceContractKey)":\(SummaryGenerator.nutritionEvidenceContractVersion)}
            """
        try db.write { database in
            try WeeklySummary(
                weekStartDate: "2026-07-13",
                summaryText: "已过时但带当前标记：摄入 0 kcal",
                findingsJson: currentMarker,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 周评",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
        }

        let text = try await SummaryGenerator(database: db).rebuildWeeklyForLLM(weekStart: "2026-07-13")
        let stored = try db.read { database in
            try WeeklySummary.fetchOne(database, key: "2026-07-13")
        }

        XCTAssertTrue(text?.contains("摄入 100 kcal") == true)
        XCTAssertFalse(text?.contains("摄入 0 kcal") == true)
        XCTAssertNil(stored?.llmText)
        XCTAssertNil(stored?.llmModel)
        XCTAssertNil(stored?.llmGeneratedAt)
    }

    func test_disabledAugmentationStillRebuildsDailyAndWeeklyBeforeReturningWithoutNetwork() async throws {
        let previousEnabled = LLMConfig.enabled
        LLMConfig.enabled = false
        defer { LLMConfig.enabled = previousEnabled }

        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        try seedMeal(db, at: day.addingTimeInterval(8 * 3_600), calories: 100)
        let currentMarker = """
            {"\(SummaryGenerator.nutritionEvidenceContractKey)":\(SummaryGenerator.nutritionEvidenceContractVersion)}
            """
        try db.write { database in
            try DailySummary(
                date: "2026-07-14",
                summaryText: "已过时但带当前标记：摄入 0 kcal",
                keyFindingsJson: currentMarker,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 评注",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
            try WeeklySummary(
                weekStartDate: "2026-07-13",
                summaryText: "已过时但带当前标记：摄入 0 kcal",
                findingsJson: currentMarker,
                qualityScore: nil,
                generatedAt: 1,
                llmText: "旧 AI 周评",
                llmModel: "legacy",
                llmGeneratedAt: 2
            ).insert(database)
        }

        let generator = SummaryGenerator(database: db)
        let dailyCommentary = try await generator.augmentDailyWithLLM(for: "2026-07-14")
        let weeklyCommentary = try await generator.augmentWeeklyWithLLM(weekStart: "2026-07-13")
        let stored = try db.read { database in
            (
                try DailySummary.fetchOne(database, key: "2026-07-14"),
                try WeeklySummary.fetchOne(database, key: "2026-07-13")
            )
        }

        XCTAssertNil(dailyCommentary)
        XCTAssertNil(weeklyCommentary)
        XCTAssertTrue(stored.0?.summaryText?.contains("摄入 100 kcal") == true)
        XCTAssertTrue(stored.1?.summaryText?.contains("摄入 100 kcal") == true)
        XCTAssertNil(stored.0?.llmText)
        XCTAssertNil(stored.0?.llmModel)
        XCTAssertNil(stored.0?.llmGeneratedAt)
        XCTAssertNil(stored.1?.llmText)
        XCTAssertNil(stored.1?.llmModel)
        XCTAssertNil(stored.1?.llmGeneratedAt)
    }

    func test_dailySummaryIncludesLastSecondAndExcludesNextMidnight() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        try seedMeal(db, at: nextDay.addingTimeInterval(-1), calories: 100)
        try seedMeal(db, at: nextDay, calories: 999)

        let summary = try await SummaryGenerator(database: db).generateDaily(for: "2026-07-14")
        let text = try XCTUnwrap(summary.summaryText)
        let findings = try jsonObject(summary.keyFindingsJson)

        XCTAssertTrue(text.contains("1 餐"))
        XCTAssertTrue(text.contains("摄入 100 kcal"))
        XCTAssertFalse(text.contains("999"))
        XCTAssertEqual(findings["mealCount"] as? Int, 1)
    }

    func test_weeklySummaryIncludesSeventhDayLastSecondAndExcludesEighthMidnight() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let weekStart = try XCTUnwrap(date("2026-07-13 00:00:00", calendar: calendar))
        let eighthDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: weekStart))
        try seedMeal(db, at: eighthDay.addingTimeInterval(-1), calories: 100)
        try seedMeal(db, at: eighthDay, calories: 999)

        let summary = try await SummaryGenerator(database: db).generateWeekly(weekStart: "2026-07-13")
        let text = try XCTUnwrap(summary.summaryText)
        let findings = try jsonObject(summary.findingsJson)

        XCTAssertTrue(text.contains("1 餐"))
        XCTAssertTrue(text.contains("摄入 100 kcal"))
        XCTAssertFalse(text.contains("999"))
        XCTAssertEqual(findings["mealCount"] as? Int, 1)
    }

    func test_dailySummaryPreservesCompleteZeroAndRejectsNegativeCalories() async throws {
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))

        let zeroDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedMeal(zeroDatabase, at: day.addingTimeInterval(8 * 3_600), calories: 0)
        let zero = try await SummaryGenerator(database: zeroDatabase).generateDaily(for: "2026-07-14")
        XCTAssertTrue(zero.summaryText?.contains("摄入 0 kcal") == true)
        XCTAssertEqual(
            (try jsonObject(zero.keyFindingsJson)["caloriesIn"] as? NSNumber)?.doubleValue,
            0
        )

        let negativeDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedMeal(negativeDatabase, at: day.addingTimeInterval(8 * 3_600), calories: -1)
        let negative = try await SummaryGenerator(database: negativeDatabase).generateDaily(for: "2026-07-14")
        XCTAssertTrue(negative.summaryText?.contains("热量记录不完整") == true)
        XCTAssertNil(try jsonObject(negative.keyFindingsJson)["caloriesIn"])
    }

    func test_dailySummaryRejectsPersistedNegativeProteinWithoutInvalidatingCalories() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))
        try seedMeal(
            db,
            at: day.addingTimeInterval(8 * 3_600),
            calories: 100,
            protein: -1,
            fat: -2,
            carbs: -3
        )

        let summary = try await SummaryGenerator(database: db).generateDaily(for: "2026-07-14")
        let text = try XCTUnwrap(summary.summaryText)
        let findings = try jsonObject(summary.keyFindingsJson)

        XCTAssertTrue(text.contains("摄入 100 kcal"))
        XCTAssertTrue(text.contains("蛋白质记录不完整"))
        XCTAssertEqual((findings["caloriesIn"] as? NSNumber)?.doubleValue, 100)
        XCTAssertNil(findings["proteinIn"])
        XCTAssertEqual(findings["proteinInStatus"] as? String, "incomplete")
    }

    func test_summariesRejectPersistedInfinityAndFiniteSumOverflow() async throws {
        let calendar = Calendar.current
        let day = try XCTUnwrap(date("2026-07-14 00:00:00", calendar: calendar))

        let infinityDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedMeal(infinityDatabase, at: day.addingTimeInterval(8 * 3_600), calories: .infinity)
        let infinitySummary = try await SummaryGenerator(database: infinityDatabase)
            .generateDaily(for: "2026-07-14")
        XCTAssertTrue(infinitySummary.summaryText?.contains("热量记录不完整") == true)
        XCTAssertNil(try jsonObject(infinitySummary.keyFindingsJson)["caloriesIn"])

        let overflowDatabase = DatabaseManager.makeInMemoryForTesting()
        try seedMeal(
            overflowDatabase,
            at: day.addingTimeInterval(8 * 3_600),
            calories: .greatestFiniteMagnitude
        )
        try seedMeal(
            overflowDatabase,
            at: day.addingTimeInterval(13 * 3_600),
            calories: .greatestFiniteMagnitude
        )
        let overflowSummary = try await SummaryGenerator(database: overflowDatabase)
            .generateWeekly(weekStart: "2026-07-13")
        XCTAssertTrue(overflowSummary.summaryText?.contains("热量记录不完整") == true)
        XCTAssertNil(try jsonObject(overflowSummary.findingsJson)["caloriesIn"])
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

    private func date(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func jsonObject(_ value: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(value?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
