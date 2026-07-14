import XCTest

@testable import HealthManager

final class TodayEvidencePresentationTests: XCTestCase {
    func testDateAndTimelineTimeUseInjectedCalendarLocaleAndTwentyFourHourClock() throws {
        let calendar = makeCalendar()
        let locale = Locale(identifier: "zh_CN")
        let dayStart = try makeDate("2026-07-14 00:00:00", calendar: calendar)
        let nextDay = try makeDate("2026-07-15 00:00:00", calendar: calendar)
        let mealTime = try makeDate("2026-07-14 08:12:00", calendar: calendar)
        let meal = makeMeal(id: 1, kind: .breakfast, at: mealTime)

        let first = TodayEvidencePresentation(
            calendar: calendar,
            locale: locale,
            snapshot: makeSnapshot(
                dayStart: dayStart,
                calendar: calendar,
                timelineEntries: [.meal(meal)]
            )
        )
        let second = TodayEvidencePresentation(
            calendar: calendar,
            locale: locale,
            snapshot: makeSnapshot(dayStart: nextDay, calendar: calendar)
        )

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")

        XCTAssertEqual(first.headerTitle, "今日")
        XCTAssertEqual(first.dateText, formatter.string(from: dayStart))
        XCTAssertEqual(second.dateText, formatter.string(from: nextDay))
        XCTAssertNotEqual(first.dateText, second.dateText)
        XCTAssertEqual(first.timelineRows.first?.timeText, "08:12")

        let englishLocale = Locale(identifier: "en_US")
        let english = TodayEvidencePresentation(
            calendar: calendar,
            locale: englishLocale,
            snapshot: makeSnapshot(dayStart: dayStart, calendar: calendar)
        )
        formatter.locale = englishLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        XCTAssertEqual(english.dateText, formatter.string(from: dayStart))
        XCTAssertFalse(english.dateText.contains("月"))
    }

    func testResolvedInterfaceLocaleUsesPreferredLanguageAndEnvironmentRegion() throws {
        let resolved = TodayEvidencePresentation.resolvedInterfaceLocale(
            environmentLocale: Locale(identifier: "en_CN"),
            preferredLanguages: ["zh-Hans"]
        )
        let fallback = TodayEvidencePresentation.resolvedInterfaceLocale(
            environmentLocale: Locale(identifier: "en_CN"),
            preferredLanguages: []
        )
        let explicitRegion = TodayEvidencePresentation.resolvedInterfaceLocale(
            environmentLocale: Locale(identifier: "en_CN"),
            preferredLanguages: ["en-GB"]
        )

        XCTAssertTrue(resolved.identifier.hasPrefix("zh"))
        XCTAssertTrue(resolved.identifier.contains("CN"))
        XCTAssertEqual(fallback.identifier, Locale(identifier: "en_CN").identifier)
        XCTAssertTrue(explicitRegion.identifier.hasPrefix("en"))
        XCTAssertTrue(explicitRegion.identifier.contains("GB"))

        let calendar = makeCalendar()
        let dayStart = try makeDate("2026-07-14 00:00:00", calendar: calendar)
        let presentation = TodayEvidencePresentation(
            calendar: calendar,
            locale: resolved,
            snapshot: makeSnapshot(dayStart: dayStart, calendar: calendar)
        )
        XCTAssertTrue(presentation.dateText.contains("月"))
        XCTAssertTrue(presentation.dateText.contains("星期"))
    }

    func testSleepSummaryPreservesUnknownZeroAndSevenHoursTwentyFourMinutes() {
        let unknown = presentation(
            aggregate: makeAggregate(asleepSeconds: nil)
        ).sleepSummary
        let zero = presentation(
            aggregate: makeAggregate(asleepSeconds: 0)
        ).sleepSummary
        let known = presentation(
            aggregate: makeAggregate(asleepSeconds: 7 * 3_600 + 24 * 60)
        ).sleepSummary

        XCTAssertEqual(unknown.valueText, "暂无睡眠汇总")
        XCTAssertNil(unknown.detailText)
        XCTAssertEqual(zero.valueText, "0 分钟")
        XCTAssertEqual(known.valueText, "7 小时 24 分钟")
        XCTAssertFalse(known.accessibilityLabel.contains("昨夜"))
        XCTAssertFalse(known.accessibilityLabel.contains("起床"))
    }

    func testActivitySummaryPreservesUnknownZeroAndKnownParts() {
        let unknown = presentation(aggregate: makeAggregate()).activitySummary
        XCTAssertEqual(unknown.valueText, "暂无活动汇总")
        XCTAssertNil(unknown.detailText)

        let zero = presentation(
            aggregate: makeAggregate(
                steps: 0,
                activeEnergyKcal: 0,
                distanceM: 0,
                exerciseMinutes: 0
            )
        ).activitySummary
        XCTAssertEqual(zero.valueText, "0 步")
        XCTAssertEqual(zero.detailText, "0 m · 0 kcal · 0 分钟")

        let known = presentation(
            aggregate: makeAggregate(
                steps: 2_340,
                activeEnergyKcal: 98,
                distanceM: 1_600,
                exerciseMinutes: 20
            )
        ).activitySummary
        XCTAssertEqual(known.valueText, "2,340 步")
        XCTAssertEqual(known.detailText, "1.6 km · 98 kcal · 20 分钟")
    }

    func testEnergySummaryDistinguishesCompleteNoMealsIncompleteAndMissingBurn() {
        let noMeals = presentation(
            energy: EnergyBalanceEvidence(
                activeKcal: 100,
                basalKcal: 1_500,
                intake: .noMeals
            )
        ).energySummary
        XCTAssertEqual(noMeals.valueText, "尚无餐次证据")
        XCTAssertNil(noMeals.detailText)

        let incomplete = presentation(
            energy: EnergyBalanceEvidence(
                activeKcal: 100,
                basalKcal: 1_500,
                intake: .incomplete
            )
        ).energySummary
        XCTAssertEqual(incomplete.valueText, "餐次热量不完整")

        let missingBurn = presentation(
            energy: EnergyBalanceEvidence(
                activeKcal: nil,
                basalKcal: 1_500,
                intake: .complete(412)
            )
        ).energySummary
        XCTAssertEqual(missingBurn.valueText, "消耗数据不足")

        let deficit = presentation(
            energy: EnergyBalanceEvidence(
                activeKcal: 98,
                basalKcal: 1_500,
                intake: .complete(412)
            )
        ).energySummary
        XCTAssertEqual(deficit.valueText, "缺口 1,186 kcal")
        XCTAssertEqual(deficit.detailText, "消耗 1,598 kcal · 摄入 412 kcal")

        let surplus = presentation(
            energy: EnergyBalanceEvidence(
                activeKcal: 100,
                basalKcal: 1_000,
                intake: .complete(1_300)
            )
        ).energySummary
        XCTAssertEqual(surplus.valueText, "盈余 200 kcal")
        XCTAssertEqual(surplus.detailText, "消耗 1,100 kcal · 摄入 1,300 kcal")
    }

    func testMealRowsMapKindsKnownZeroIncompleteMacrosAndProvenanceWithoutInference() throws {
        let calendar = makeCalendar()
        let base = try makeDate("2026-07-14 08:00:00", calendar: calendar)
        let meals: [TodayTimelineEvidenceEntry] = [
            .meal(makeMeal(
                id: 1,
                kind: .breakfast,
                at: base,
                totals: MealNutritionTotals(
                    caloriesKcal: 0,
                    proteinG: 0,
                    fatG: nil,
                    carbsG: 12.5
                ),
                provenance: []
            )),
            .meal(makeMeal(
                id: 2,
                kind: .lunch,
                at: base.addingTimeInterval(60),
                totals: MealNutritionTotals(
                    caloriesKcal: nil,
                    proteinG: nil,
                    fatG: nil,
                    carbsG: nil
                ),
                provenance: [.manual]
            )),
            .meal(makeMeal(
                id: 3,
                kind: .dinner,
                at: base.addingTimeInterval(120),
                provenance: [.aiEstimate, .nutritionDatabase]
            )),
            .meal(makeMeal(
                id: 4,
                kind: .snack,
                at: base.addingTimeInterval(180),
                provenance: [.nutritionLabel]
            ))
        ]

        let rows = TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: makeSnapshot(calendar: calendar, timelineEntries: meals)
        ).timelineRows

        XCTAssertEqual(rows.map(\.id), ["meal-1", "meal-2", "meal-3", "meal-4"])
        XCTAssertEqual(rows.map(\.kind), [.meal, .meal, .meal, .meal])
        XCTAssertEqual(rows.map(\.title), ["早餐", "午餐", "晚餐", "加餐"])
        XCTAssertEqual(rows[0].primaryText, "0 kcal")
        XCTAssertEqual(rows[0].detailText, "P 0 g · C 12.5 g")
        XCTAssertEqual(rows[0].metadataText, "来源未记录")
        XCTAssertEqual(rows[1].primaryText, "热量未完整记录")
        XCTAssertNil(rows[1].detailText)
        XCTAssertEqual(rows[1].metadataText, "来源：手动录入")
        XCTAssertEqual(rows[2].metadataText, "来源：AI 估算、营养数据库")
        XCTAssertEqual(rows[3].metadataText, "来源：营养标签")
    }

    func testMedicationRowsPreserveAllActionsAndStrictlySeparateActionFromPlanTime() throws {
        let calendar = makeCalendar()
        let actionTime = try makeDate("2026-07-14 08:12:00", calendar: calendar)
        let scheduledTime = try makeDate("2026-07-14 20:00:00", calendar: calendar)
        let skippedTime = try makeDate("2026-07-14 21:05:00", calendar: calendar)
        let rows = TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: makeSnapshot(
                calendar: calendar,
                timelineEntries: [
                    .medication(makeMedication(
                        id: 10,
                        name: "奥美拉唑",
                        scheduledAt: actionTime.addingTimeInterval(180),
                        actionAt: actionTime,
                        action: .taken,
                        dosageMg: 20
                    )),
                    .medication(makeMedication(
                        id: 11,
                        name: "奥美拉唑",
                        scheduledAt: scheduledTime,
                        actionAt: nil,
                        action: .deferred,
                        dosageMg: nil
                    )),
                    .medication(makeMedication(
                        id: 12,
                        name: nil,
                        scheduledAt: skippedTime.addingTimeInterval(-60),
                        actionAt: skippedTime,
                        action: .skipped,
                        dosageMg: nil
                    ))
                ]
            )
        ).timelineRows

        XCTAssertEqual(rows.map(\.id), ["medication-10", "medication-11", "medication-12"])
        XCTAssertEqual(rows.map(\.kind), [.medication, .medication, .medication])
        XCTAssertEqual(rows[0].timeText, "08:12")
        XCTAssertEqual(rows[0].primaryText, "已服用 20 mg")
        XCTAssertNil(rows[0].detailText)
        XCTAssertTrue(rows[0].accessibilityLabel.contains("动作时间 08:12"))

        XCTAssertEqual(rows[1].timeText, "计划 20:00")
        XCTAssertEqual(rows[1].primaryText, "已延后")
        XCTAssertEqual(rows[1].detailText, "动作时刻未记录")
        XCTAssertTrue(rows[1].accessibilityLabel.contains("计划时间 20:00"))
        XCTAssertTrue(rows[1].accessibilityLabel.contains("动作时刻未记录"))
        XCTAssertFalse(rows[1].accessibilityLabel.contains("动作时间 20:00"))

        XCTAssertEqual(rows[2].title, "用药记录")
        XCTAssertEqual(rows[2].primaryText, "已跳过")
    }

    func testQualityPillPrioritizesUnacknowledgedAlertsThenReconciliationState() {
        let unreconciled = presentation(
            quality: makeQuality(wasReconciled: false)
        )
        XCTAssertEqual(unreconciled.qualityText, "尚未对账")
        XCTAssertEqual(unreconciled.qualityStyle, .unreconciled)

        let reconciled = presentation(
            quality: makeQuality(wasReconciled: true)
        )
        XCTAssertEqual(reconciled.qualityText, "暂无待确认")
        XCTAssertEqual(reconciled.qualityStyle, .reconciledNoAlerts)

        let alerts = [
            TodayDataAlertEvidence(
                id: 1,
                metric: "sleep",
                severity: .warning,
                message: nil,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            TodayDataAlertEvidence(
                id: 2,
                metric: "steps",
                severity: .info,
                message: nil,
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ]
        let alertState = presentation(
            quality: makeQuality(wasReconciled: false, alerts: alerts)
        )
        XCTAssertEqual(alertState.qualityText, "2 项待确认")
        XCTAssertEqual(alertState.qualityStyle, .hasAlerts)
    }

    func testSourceCoverageMapsAllOriginsOneToOneInLoaderOrderAndHasEmptyState() {
        let evidence: [TodaySourceCoverageEvidence] = [
            .init(origin: .garmin, sourceName: "Garmin Connect", sampleCount: 1, lastIngestedAt: nil),
            .init(origin: .xiaomiMijia, sourceName: nil, sampleCount: 2, lastIngestedAt: nil),
            .init(origin: .xiaomiSports, sourceName: "Zepp Life", sampleCount: 3, lastIngestedAt: nil),
            .init(origin: .apple, sourceName: "Apple Watch", sampleCount: 4, lastIngestedAt: nil),
            .init(origin: .hutool, sourceName: nil, sampleCount: 5, lastIngestedAt: nil),
            .init(origin: .manual, sourceName: "健康管理", sampleCount: 6, lastIngestedAt: nil),
            .init(origin: .unknown, sourceName: "Device", sampleCount: 7, lastIngestedAt: nil)
        ]
        let rows = presentation(sourceCoverage: evidence).sourceCoverageRows

        XCTAssertEqual(rows.count, evidence.count)
        XCTAssertEqual(
            rows.map(\.title),
            [
                "Garmin",
                "米家 / 小米健康",
                "小米运动 / Zepp",
                "Apple Health / Watch",
                "华为 / 华米",
                "手动录入",
                "未识别来源"
            ]
        )
        XCTAssertEqual(rows[0].detailText, "Garmin Connect · 1 条样本")
        XCTAssertEqual(rows[1].detailText, "2 条样本")
        XCTAssertEqual(rows[6].detailText, "Device · 7 条样本")
        XCTAssertEqual(
            presentation(sourceCoverage: []).sourceCoverageEmptyText,
            "当日暂无原始样本来源记录"
        )
    }

    func testTimelineRowsPreserveLoaderOrderAndEntryIdentity() throws {
        let calendar = makeCalendar()
        let late = try makeDate("2026-07-14 12:00:00", calendar: calendar)
        let early = try makeDate("2026-07-14 08:00:00", calendar: calendar)
        let snapshot = makeSnapshot(
            calendar: calendar,
            timelineEntries: [
                .meal(makeMeal(id: 9, kind: .lunch, at: late)),
                .medication(makeMedication(
                    id: 9,
                    name: "A",
                    scheduledAt: early,
                    actionAt: early,
                    action: .taken,
                    dosageMg: nil
                ))
            ]
        )

        let presentation = TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: snapshot
        )

        XCTAssertEqual(presentation.timelineRows.map(\.id), ["meal-9", "medication-9"])
        XCTAssertEqual(presentation.timelineRows.map(\.timeText), ["12:00", "08:00"])
        XCTAssertEqual(presentation.timelineEmptyText, "今天还没有餐食或用药记录")
    }

    func testInvalidConstructedNumbersNeverBecomeFabricatedZero() throws {
        let calendar = makeCalendar()
        let mealTime = try makeDate("2026-07-14 12:00:00", calendar: calendar)
        let aggregate = makeAggregate(
            steps: -1,
            activeEnergyKcal: .infinity,
            distanceM: .nan,
            exerciseMinutes: -2
        )
        let meal = makeMeal(
            id: 1,
            kind: .lunch,
            at: mealTime,
            totals: MealNutritionTotals(
                caloriesKcal: .infinity,
                proteinG: -1,
                fatG: .nan,
                carbsG: nil
            )
        )
        let result = TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: makeSnapshot(
                calendar: calendar,
                aggregate: aggregate,
                timelineEntries: [.meal(meal)]
            )
        )

        XCTAssertEqual(result.activitySummary.valueText, "暂无活动汇总")
        XCTAssertEqual(result.timelineRows.first?.primaryText, "热量未完整记录")
        XCTAssertNil(result.timelineRows.first?.detailText)
        XCTAssertFalse(result.timelineRows.first?.accessibilityLabel.contains("0 kcal") ?? true)
    }

    func testGeneratedCopyContainsNoForbiddenProductInference() throws {
        let calendar = makeCalendar()
        let fallback = try makeDate("2026-07-14 20:00:00", calendar: calendar)
        let result = TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: makeSnapshot(
                calendar: calendar,
                aggregate: makeAggregate(asleepSeconds: nil),
                timelineEntries: [
                    .medication(makeMedication(
                        id: 1,
                        name: "A",
                        scheduledAt: fallback,
                        actionAt: nil,
                        action: .deferred,
                        dosageMg: nil
                    ))
                ]
            )
        )
        let allCopy = [
            result.dateText,
            result.sleepSummary.accessibilityLabel,
            result.activitySummary.accessibilityLabel,
            result.energySummary.accessibilityLabel,
            result.timelineRows.map(\.accessibilityLabel).joined(separator: " "),
            result.timelineEmptyText,
            result.sourceCoverageEmptyText
        ].joined(separator: " ")

        for forbidden in ["昨夜", "尚未记录午餐", "午餐待记录", "漏服", "食物数据库"] {
            XCTAssertFalse(allCopy.contains(forbidden), "unexpected product inference: \(forbidden)")
        }
    }

    private func presentation(
        aggregate: TodayDailyAggregateEvidence? = nil,
        energy: EnergyBalanceEvidence = EnergyBalanceEvidence(
            activeKcal: nil,
            basalKcal: nil,
            intake: .noMeals
        ),
        quality: TodayDataQualityEvidence? = nil,
        sourceCoverage: [TodaySourceCoverageEvidence] = []
    ) -> TodayEvidencePresentation {
        let calendar = makeCalendar()
        return TodayEvidencePresentation(
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            snapshot: makeSnapshot(
                calendar: calendar,
                aggregate: aggregate,
                energy: energy,
                quality: quality,
                sourceCoverage: sourceCoverage
            )
        )
    }

    private func makeSnapshot(
        dayStart: Date? = nil,
        calendar: Calendar? = nil,
        aggregate: TodayDailyAggregateEvidence? = nil,
        timelineEntries: [TodayTimelineEvidenceEntry] = [],
        energy: EnergyBalanceEvidence = EnergyBalanceEvidence(
            activeKcal: nil,
            basalKcal: nil,
            intake: .noMeals
        ),
        quality: TodayDataQualityEvidence? = nil,
        sourceCoverage: [TodaySourceCoverageEvidence] = []
    ) -> TodayEvidenceSnapshot {
        let resolvedCalendar = calendar ?? makeCalendar()
        let resolvedAggregate = aggregate ?? makeAggregate()
        let resolvedQuality = quality ?? makeQuality(wasReconciled: false)
        let resolvedStart = dayStart ?? DateComponents(
            calendar: resolvedCalendar,
            timeZone: resolvedCalendar.timeZone,
            year: 2026,
            month: 7,
            day: 14
        ).date!
        let end = resolvedCalendar.date(byAdding: .day, value: 1, to: resolvedStart)!
        return TodayEvidenceSnapshot(
            dayStart: resolvedStart,
            dayEndExclusive: end,
            dayKey: "2026-07-14",
            dailyAggregate: resolvedAggregate,
            timelineEntries: timelineEntries,
            nutrition: .empty,
            energyBalance: energy,
            dataQuality: resolvedQuality,
            sourceCoverage: sourceCoverage
        )
    }

    private func makeAggregate(
        asleepSeconds: Int? = nil,
        steps: Int? = nil,
        activeEnergyKcal: Double? = nil,
        basalEnergyKcal: Double? = nil,
        distanceM: Double? = nil,
        exerciseMinutes: Double? = nil
    ) -> TodayDailyAggregateEvidence {
        TodayDailyAggregateEvidence(
            wasComputed: true,
            computedAt: nil,
            asleepSeconds: asleepSeconds,
            steps: steps,
            activeEnergyKcal: activeEnergyKcal,
            basalEnergyKcal: basalEnergyKcal,
            distanceM: distanceM,
            exerciseMinutes: exerciseMinutes
        )
    }

    private func makeMeal(
        id: Int64,
        kind: TodayMealKind,
        at date: Date,
        totals: MealNutritionTotals = MealNutritionTotals(
            caloriesKcal: 412,
            proteinG: 23,
            fatG: 14,
            carbsG: 46
        ),
        provenance: [TodayMealProvenanceKind] = [.manual]
    ) -> TodayMealEvidence {
        TodayMealEvidence(
            id: id,
            mealType: kind,
            eatenAt: date,
            timelineAt: date,
            timeBasis: .eatenTime,
            totals: totals,
            itemCount: 1,
            provenanceKinds: provenance,
            hasUserEditedItem: false
        )
    }

    private func makeMedication(
        id: Int64,
        name: String?,
        scheduledAt: Date,
        actionAt: Date?,
        action: TodayMedicationAction,
        dosageMg: Double?
    ) -> TodayMedicationEvidence {
        TodayMedicationEvidence(
            id: id,
            planID: nil,
            planName: name,
            scheduledAt: scheduledAt,
            actionAt: actionAt,
            timelineAt: actionAt ?? scheduledAt,
            timeBasis: actionAt == nil ? .scheduledFallback : .actionTime,
            action: action,
            dosageMg: dosageMg
        )
    }

    private func makeQuality(
        wasReconciled: Bool,
        alerts: [TodayDataAlertEvidence] = []
    ) -> TodayDataQualityEvidence {
        TodayDataQualityEvidence(
            wasReconciled: wasReconciled,
            computedAt: nil,
            completenessScore: nil,
            freshnessScore: nil,
            conflictScore: nil,
            missingMetricKeys: wasReconciled ? [] : nil,
            alerts: alerts
        )
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func makeDate(_ value: String, calendar: Calendar) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try XCTUnwrap(formatter.date(from: value))
    }
}
