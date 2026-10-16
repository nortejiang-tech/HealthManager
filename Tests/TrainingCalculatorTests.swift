import XCTest
import GRDB
@testable import HealthManager

final class TrainingCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))! }
    private func sample(_ type: String, _ value: Double, _ start: Date, end: Date? = nil,
                        source: String = "watch-A", motion: Int? = nil) -> TrainingSample {
        TrainingSample(id: UUID().uuidString, type: type, value: value, start: start, end: end ?? start,
            source: source, sourceName: source, origin: "apple", ingestedAt: start, motionContext: motion)
    }
    private func workout(_ start: Date, seconds: Double = 1800, distance: Double? = 5000,
                         source: String = "watch-A", heart: Double = 150) -> [TrainingSample] {
        var w = sample(TrainingTypes.workout, seconds, start, end: start.addingTimeInterval(seconds), source: source)
        w.activityType = 37; w.duration = seconds; w.distance = distance
        var result = [w]
        for offset in stride(from: 0.0, to: seconds, by: 10) {
            result.append(sample(TrainingTypes.heart, heart, start.addingTimeInterval(offset), source: source))
        }
        result += [sample(TrainingTypes.heart, heart, w.end, source: source),
                   sample(TrainingTypes.heart, heart - 30, w.end.addingTimeInterval(60), source: source),
                   sample(TrainingTypes.heart, heart - 50, w.end.addingTimeInterval(120), source: source)]
        return result
    }
    private func resting(before date: Date, source: String = "watch-A") -> [TrainingSample] {
        (1...10).map { sample(TrainingTypes.resting, 60, date.addingTimeInterval(-Double($0) * 86_400), source: source) }
    }
    private func snapshot(_ samples: [TrainingSample]) -> TrainingSnapshot {
        TrainingCalculator.snapshot(samples: samples, now: now, calendar: calendar)
    }
    private func validHistory(currentHours: Double = 8, currentHRV: Double = 40, currentHeart: Double = 50) -> [TrainingSample] {
        var result: [TrainingSample] = []
        let today = calendar.startOfDay(for: now)
        for day in 0..<24 {
            let wake = calendar.date(byAdding: .day, value: -day, to: today)!
            let previous = calendar.date(byAdding: .day, value: -1, to: wake)!
            let start = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: previous)!
            let hours = day == 0 ? currentHours : 8
            result.append(sample(TrainingTypes.sleep, 3, start, end: start.addingTimeInterval(hours * 3600)))
            for offset in [60.0, 180, 300] where offset < hours * 60 {
                result.append(sample(TrainingTypes.hrv, day == 0 ? currentHRV : 40, start.addingTimeInterval(offset * 60)))
            }
            for offset in stride(from: 0.0, to: hours * 60, by: 20) {
                result.append(sample(TrainingTypes.heart, day == 0 ? currentHeart : 50, start.addingTimeInterval(offset * 60)))
            }
            result.append(sample(TrainingTypes.resting, 60, wake.addingTimeInterval(7 * 3600)))
        }
        for day in [3, 6, 9, 12] {
            result += workout(today.addingTimeInterval(-Double(day) * 86_400 + 17 * 3600))
        }
        return result
    }

    func test_emptyInputWithholdsReadinessAndLoad() {
        let s = snapshot([])
        XCTAssertNil(s.readiness.score)
        XCTAssertEqual(s.days.count, 56)
        XCTAssertTrue(s.days.allSatisfy { $0.recordedLoad == nil })
        XCTAssertTrue(s.intraday.isEmpty)
        XCTAssertNil(s.latestMeasurementAt)
    }

    func test_completeHeartTraceCalculatesPaceLoadAndSignedRecovery() throws {
        let start = now.addingTimeInterval(-3600)
        let s = try XCTUnwrap(snapshot(resting(before: start) + workout(start)).sessions.first)
        XCTAssertEqual(try XCTUnwrap(s.paceSecondsPerKm), 360, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.averageHeartRate), 150, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.load), 2700, accuracy: 0.01)
        XCTAssertEqual(s.heartCoverage, 1, accuracy: 0.001)
        XCTAssertEqual(s.recovery60, 30)
        XCTAssertEqual(s.recovery120, 50)
    }

    func test_longHeartGapIsNotFilled() throws {
        let start = now.addingTimeInterval(-3600)
        let trace = workout(start).filter { $0.type == TrainingTypes.workout || $0.start == start }
        let s = try XCTUnwrap(snapshot(resting(before: start) + trace).sessions.first)
        XCTAssertLessThan(s.heartCoverage, 0.1)
        XCTAssertNil(s.load)
        XCTAssertNil(s.averageHeartRate)
    }

    func test_foreignHeartSourceCannotSupplySessionLoadOrRecovery() throws {
        let start = now.addingTimeInterval(-3600)
        let trace = workout(start).map { input -> TrainingSample in
            var s = input
            if s.type == TrainingTypes.heart { s.source = "watch-B" }
            return s
        }
        let s = try XCTUnwrap(snapshot(resting(before: start) + trace).sessions.first)
        XCTAssertNil(s.load)
        XCTAssertNil(s.recovery60)
        XCTAssertEqual(s.heartCoverage, 0)
    }

    func test_foreignRestingBaselineCannotSupplyReference() throws {
        let start = now.addingTimeInterval(-3600)
        let s = try XCTUnwrap(snapshot(resting(before: start, source: "watch-B") + workout(start)).sessions.first)
        XCTAssertNil(s.restingReference)
        XCTAssertNil(s.load)
    }

    func test_duplicateHeartTimestampsDoNotMultiplyLoad() throws {
        let start = now.addingTimeInterval(-3600)
        let trace = workout(start)
        let duplicates = trace.filter { $0.type == TrainingTypes.heart }.map { input -> TrainingSample in
            var s = input; s.id = UUID().uuidString; return s
        }
        let s = try XCTUnwrap(snapshot(resting(before: start) + trace + duplicates).sessions.first)
        XCTAssertEqual(try XCTUnwrap(s.load), 2700, accuracy: 0.01)
    }

    func test_crossDeviceDuplicateWorkoutIsCountedOnce() throws {
        let start = now.addingTimeInterval(-3600)
        let trace = workout(start)
        var duplicate = try XCTUnwrap(trace.first)
        duplicate.id = "other-workout"; duplicate.source = "watch-B"; duplicate.origin = "unknown"
        let s = snapshot(trace + [duplicate])
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.days.last?.runKm, 5)
    }

    func test_missingDistanceStaysUnknown() throws {
        let s = snapshot(workout(now.addingTimeInterval(-3600), distance: nil))
        XCTAssertNil(s.sessions.first?.paceSecondsPerKm)
        XCTAssertNil(s.sessions.first?.distanceKm)
        XCTAssertEqual(s.days.last?.missingDistanceCount, 1)
    }

    func test_pauseAmbiguityWithholdsLoad() throws {
        let start = now.addingTimeInterval(-3600)
        var trace = workout(start)
        trace[0].duration = 1200
        let s = try XCTUnwrap(snapshot(resting(before: start) + trace).sessions.first)
        XCTAssertNil(s.load)
        XCTAssertTrue(s.notes.contains { $0.contains("暂停") })
    }

    func test_futureAndNonfiniteDataDoNotChangeSnapshot() {
        var future = sample(TrainingTypes.heart, 200, now.addingTimeInterval(60))
        future.ingestedAt = now
        let invalid = sample(TrainingTypes.heart, .nan, now.addingTimeInterval(-60))
        let s = snapshot([future, invalid])
        XCTAssertNil(s.latestMeasurementAt)
        XCTAssertTrue(s.sessions.isEmpty)
    }

    func test_lateArrivingSampleIsUnavailableToHistoricalReplay() {
        var late = sample(TrainingTypes.heart, 70, now.addingTimeInterval(-3600))
        late.ingestedAt = now.addingTimeInterval(60)
        XCTAssertNil(snapshot([late]).latestMeasurementAt)
    }

    func test_sleepUnionAwakeConflictAndDaytimeNap() throws {
        let today = calendar.startOfDay(for: now)
        let start = today.addingTimeInterval(-2 * 3600)
        let end = today.addingTimeInterval(6 * 3600)
        let records = [sample(TrainingTypes.sleep, 1, start, end: end),
                       sample(TrainingTypes.sleep, 3, start, end: end),
                       sample(TrainingTypes.sleep, 2, today, end: today.addingTimeInterval(1800)),
                       sample(TrainingTypes.hrv, 40, today.addingTimeInterval(3600))]
        let night = try XCTUnwrap(snapshot(records).latestNight)
        XCTAssertEqual(night.hours, 7.5, accuracy: 0.001)
        XCTAssertTrue(night.hasConflict)
        XCTAssertEqual(night.dayKey, "2026-10-15")
        XCTAssertEqual(night.hrv, 40)
    }

    func test_afternoonNapCannotBecomeMainNight() {
        let previous = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let nap = sample(TrainingTypes.sleep, 3, previous.addingTimeInterval(14 * 3600), end: previous.addingTimeInterval(17 * 3600))
        XCTAssertNil(snapshot([nap]).latestNight)
    }

    func test_invalidSleepCategoryCannotCrashOrBecomeSleep() {
        let start = calendar.startOfDay(for: now).addingTimeInterval(-3600)
        let invalid = sample(TrainingTypes.sleep, 1e100, start, end: start.addingTimeInterval(8 * 3600))
        XCTAssertNil(snapshot([invalid]).latestNight)
    }

    func test_unknownSourceCannotSupplyAPersonalBaseline() throws {
        let start = now.addingTimeInterval(-3600)
        let s = try XCTUnwrap(snapshot(resting(before: start, source: "unknown:device") + workout(start, source: "unknown:device")).sessions.first)
        XCTAssertNil(s.restingReference)
        XCTAssertNil(s.load)
    }

    func test_readinessRequiresIndependentPriorNightsAndRespondsToRecoverySignals() throws {
        let normal = snapshot(validHistory())
        let lower = snapshot(validHistory(currentHours: 6, currentHRV: 20, currentHeart: 60))
        XCTAssertGreaterThanOrEqual(normal.readiness.baselineNights, 14)
        let normalScore = try XCTUnwrap(normal.readiness.score)
        let lowerScore = try XCTUnwrap(lower.readiness.score)
        XCTAssertLessThan(lowerScore, normalScore)
        XCTAssertTrue((0...100).contains(normalScore))
        XCTAssertTrue((0...100).contains(lowerScore))
    }

    func test_sparseCurrentHRVDoesNotRenormalizeToAHealthyScore() {
        let begin = calendar.startOfDay(for: now).addingTimeInterval(-2 * 3600)
        var history = validHistory()
        let ids = history.filter { $0.type == TrainingTypes.hrv && $0.start >= begin }.map(\.id)
        history.removeAll { ids.suffix(2).contains($0.id) }
        let s = snapshot(history)
        XCTAssertNil(s.readiness.score)
        XCTAssertTrue(s.readiness.missingReasons.contains { $0.contains("少于3") })
        XCTAssertNil(s.readiness.possibleRange)
    }

    func test_concordantAutonomicSignalsAreNotDoublePenalized() throws {
        let one = snapshot(validHistory(currentHRV: 20, currentHeart: 50))
        let both = snapshot(validHistory(currentHRV: 20, currentHeart: 60))
        XCTAssertNotNil(one.readiness.score)
        XCTAssertEqual(one.readiness.score, both.readiness.score)
        XCTAssertEqual(both.readiness.factors.filter { $0.id == "autonomic" }.count, 1)
    }

    func test_sourceChangeDoesNotReuseOldNightBaseline() {
        let begin = calendar.startOfDay(for: now).addingTimeInterval(-2 * 3600)
        let history = validHistory().map { input -> TrainingSample in
            var s = input
            if s.start >= begin { s.source = "watch-new" }
            return s
        }
        let s = snapshot(history)
        XCTAssertNil(s.readiness.score)
        XCTAssertEqual(s.readiness.baselineNights, 0)
    }

    func test_clusteredNightSamplesDoNotClaimAdequateCoverage() {
        let begin = calendar.startOfDay(for: now).addingTimeInterval(-2 * 3600)
        var index = 0
        let history = validHistory().map { input -> TrainingSample in
            var s = input
            if s.type == TrainingTypes.hrv && s.start >= begin {
                s.start = begin.addingTimeInterval(3600 + Double(index) * 60)
                s.end = s.start
                index += 1
            }
            return s
        }
        let s = snapshot(history)
        XCTAssertNil(s.readiness.score)
        XCTAssertNil(s.readiness.possibleRange)
        XCTAssertTrue(s.readiness.missingReasons.contains { $0.contains("采样跨度") })
    }

    func test_staleMainSleepWithholdsBothScoreAndRange() {
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(-26 * 3600)
        let old = validHistory().filter { $0.end < cutoff }
        let s = snapshot(old)
        XCTAssertNil(s.readiness.score)
        XCTAssertNil(s.readiness.possibleRange)
    }

    func test_missingRecentSessionLoadWithholdsReadiness() {
        let unknown = workout(now.addingTimeInterval(-3600), source: "watch-unmatched").filter { $0.type == TrainingTypes.workout }
        let s = snapshot(validHistory() + unknown)
        XCTAssertNil(s.readiness.score)
        XCTAssertTrue(s.readiness.missingReasons.contains { $0.contains("最近48小时") })
        XCTAssertNotNil(s.readiness.possibleRange)
        if let range = s.readiness.possibleRange {
            XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound, 15)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
            XCTAssertLessThanOrEqual(range.upperBound, 100)
        }
    }

    func test_partialDayPreservesKnownLoadWithoutClaimingCompleteness() throws {
        let start = now.addingTimeInterval(-3600)
        let unknown = workout(now.addingTimeInterval(-10_000), source: "other").filter { $0.type == TrainingTypes.workout }
        let s = snapshot(resting(before: start) + workout(start) + unknown)
        XCTAssertEqual(s.days.last?.missingLoadCount, 1)
        XCTAssertEqual(try XCTUnwrap(s.days.last?.recordedLoad), 2700, accuracy: 0.01)
    }

    func test_intradayWindowsRequireEvidenceAndExcludeExplicitActivity() {
        let start = calendar.startOfDay(for: now).addingTimeInterval(11 * 3600)
        let quiet = [0.0, 300, 600].map { sample(TrainingTypes.heart, 70, start.addingTimeInterval($0)) }
        let active = sample(TrainingTypes.heart, 160, start.addingTimeInterval(900), motion: 2)
        let s = snapshot(quiet + [active])
        XCTAssertEqual(s.intraday.count, 1)
        XCTAssertEqual(s.intraday.first?.heartRate, 70)
        XCTAssertEqual(s.intraday.first?.sampleCount, 3)
    }

    func test_timezoneAssignsWorkoutToLocalDate() throws {
        let start = calendar.startOfDay(for: now).addingTimeInterval(60)
        let s = snapshot(workout(start))
        XCTAssertEqual(s.days.last?.key, "2026-10-15")
        XCTAssertEqual(s.days.last?.sessionCount, 1)
    }

    func test_loaderRejectsWrongUnitsAndDeletedRecords() async throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        var raw = HealthSampleRaw(sampleUUID: "wrong-unit", hkType: TrainingTypes.heart, kind: .quantity,
            value: 70, unit: "kg", startAt: Int64(now.timeIntervalSince1970 - 60), endAt: Int64(now.timeIntervalSince1970 - 60),
            sourceName: "synthetic", sourceBundleId: "watch-A", deviceName: nil, deviceModel: nil,
            ingestedAt: Int64(now.timeIntervalSince1970 - 30), isDeleted: false, extraJson: nil, sourceOrigin: "apple")
        try db.write { try raw.insert($0) }
        raw.sampleUUID = "deleted-heart"; raw.unit = "count/min"; raw.isDeleted = true
        try db.write { try raw.insert($0) }
        let result = try await TrainingSnapshotLoader.load(database: db, now: now, calendar: calendar)
        XCTAssertNil(result.latestMeasurementAt)
        XCTAssertNil(result.readiness.score)
    }

    func test_rawRegionChangesAreObservedWithoutDailyProjectionChanges() throws {
        let db = DatabaseManager.makeInMemoryForTesting()
        let changed = expectation(description: "raw sample change")
        let token = DatabaseRegionObservation(tracking: Table("health_samples_raw")).start(in: db.pool,
            onError: { XCTFail("\($0)") }, onChange: { _ in changed.fulfill() })
        defer { token.cancel() }
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO health_samples_raw (sample_uuid,hk_type,kind,value,unit,start_at,end_at,ingested_at,is_deleted)
                VALUES ('region-test','HKQuantityTypeIdentifierHeartRate','quantity',70,'count/min',1,1,1,0)
                """)
        }
        wait(for: [changed], timeout: 3)
    }
}
