import XCTest
@testable import HealthManager

final class WorkoutFusionTests: XCTestCase {
    func testIndexedHeartWindowPreservesSourceAndBoundaryRules() throws {
        let event = try XCTUnwrap(WorkoutEventResolver.events([workout("g", origin: "garmin")]).first)
        func point(_ id: String, _ source: String, _ origin: String, _ offset: TimeInterval) -> TrainingSample {
            TrainingSample(id: id, type: TrainingTypes.heart, value: 100,
                start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset),
                source: source, sourceName: source, origin: origin, ingestedAt: start)
        }
        let all = [point("before", "g", "garmin", -31), point("hold", "g", "garmin", -30),
            point("apple", "a", "apple", 100), point("xiaomi", "x", "xiaomiSports", 100),
            point("unknown", "u", "unknown", 100), point("recovery", "a", "apple", 1935),
            point("after", "g", "garmin", 1936)]
        let indexed = WorkoutEventResolver.hearts(all, for: event, sortedByStart: true)
        XCTAssertEqual(indexed.map(\.id), ["hold", "apple", "recovery"])
        XCTAssertEqual(indexed.map(\.id), WorkoutEventResolver.hearts(all.reversed(), for: event).map(\.id))
    }

    func testPopulatedSnapshotRemainsResponsive() {
        var inputs: [TrainingSample] = []
        let now = start.addingTimeInterval(86400)
        func add(_ type: String, _ value: Double, _ at: Date, _ end: Date? = nil, duration: Double? = nil) {
            inputs.append(TrainingSample(id: "\(type)-\(at.timeIntervalSince1970)", type: type, value: value,
                start: at, end: end ?? at, source: "apple", sourceName: "synthetic", origin: "apple",
                ingestedAt: at, activityType: type == TrainingTypes.workout ? 37 : nil,
                duration: duration, distance: type == TrainingTypes.workout ? 5000 : nil))
        }
        for day in 1...100 {
            let anchor = now.addingTimeInterval(-Double(day) * 86400)
            for minute in stride(from: 0, to: 1440, by: 3) {
                add(TrainingTypes.heart, 65, anchor.addingTimeInterval(Double(minute) * 60))
            }
            let sleep = calendar.startOfDay(for: anchor).addingTimeInterval(-3600)
            for phase in 0..<16 {
                let at = sleep.addingTimeInterval(Double(phase) * 1800)
                add(TrainingTypes.sleep, 3, at, at.addingTimeInterval(1800))
            }
            add(TrainingTypes.hrv, 50, sleep.addingTimeInterval(7200))
            add(TrainingTypes.resting, 55, anchor)
            if day % 2 == 0 { add(TrainingTypes.workout, 1800, anchor, anchor.addingTimeInterval(1800), duration: 1800) }
        }
        let began = Date()
        let snapshot = TrainingCalculator.snapshot(samples: inputs, now: now, calendar: calendar)
        XCTAssertLessThan(Date().timeIntervalSince(began), 8, "Populated history must not leave the screen calculating")
        XCTAssertEqual(snapshot.days.count, 56)
        XCTAssertFalse(snapshot.sessions.isEmpty)
    }
    private let start = Date(timeIntervalSince1970: 1792730000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func workout(_ id: String, origin: String, offset: Double = 0, seconds: Double = 1800, distance: Double? = 5000) -> TrainingSample {
        TrainingSample(id: id, type: TrainingTypes.workout, value: seconds, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + seconds), source: id, sourceName: id, origin: origin, ingestedAt: start, activityType: 37, duration: seconds, distance: distance)
    }
    private func hearts(source: String, origin: String, seconds: Double, value: Double) -> [TrainingSample] {
        stride(from: 0.0, to: seconds, by: 10).map { t in
            TrainingSample(id: "\(source)-\(t)", type: TrainingTypes.heart, value: value, start: start.addingTimeInterval(t), end: start.addingTimeInterval(t), source: source, sourceName: source, origin: origin, ingestedAt: start)
        }
    }
    func testDelayedGarminDetectionMatchesAndUsesAppleCompleteWindow() throws {
        let events = WorkoutEventResolver.events([workout("g", origin: "garmin", offset: 300, seconds: 1500, distance: 4200), workout("a", origin: "apple")])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.selected.source, "g")
        XCTAssertEqual(events.first?.selected.start, start)
        XCTAssertEqual(events.first?.selected.distance, 5000)
    }
    func testHeartGapCompletionAndCrossValidationAreUsedByActualSnapshot() throws {
        let samples = [workout("g", origin: "garmin"), workout("a", origin: "apple")]
            + hearts(source: "g", origin: "garmin", seconds: 1190, value: 140)
            + hearts(source: "a", origin: "apple", seconds: 1800, value: 160)
        let snapshot = TrainingCalculator.snapshot(samples: samples, now: start.addingTimeInterval(3600), calendar: calendar)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(session.heartCoverage, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(session.averageHeartRate), (140 * 1210.0 + 160 * 590.0) / 1800, accuracy: 0.01)
        XCTAssertTrue(session.notes.contains { $0.contains("补全") })
        XCTAssertTrue(session.notes.contains { $0.contains("平均绝对差") })
        XCTAssertNil(session.load, "Cross-device load needs compatible per-source baselines")
        let detail = try XCTUnwrap(TrainingCalculator.recordDetail(id: "a", samples: samples, now: start.addingTimeInterval(3600), calendar: calendar))
        XCTAssertEqual(detail.id, session.id); XCTAssertEqual(detail.averageHeartRate, session.averageHeartRate)
    }
    func testDistancesAreNotAveragedAndAppleOnlyIsUsable() {
        let event = WorkoutEventResolver.events([workout("g", origin: "garmin", distance: 5000), workout("a", origin: "apple", distance: 5500)]).first
        XCTAssertEqual(event?.selected.distance, 5000)
        XCTAssertEqual(WorkoutEventResolver.events([workout("a", origin: "apple")]).first?.selected.source, "a")
    }
    func testAppleHeartCanFillGarminWithoutAnAppleWorkoutRecord() throws {
        let samples = [workout("g",origin:"garmin")]
            + hearts(source:"a",origin:"apple",seconds:1800,value:150)
        let session = try XCTUnwrap(TrainingCalculator.snapshot(samples:samples,now:start.addingTimeInterval(3600),calendar:calendar).sessions.first)
        XCTAssertEqual(session.averageHeartRate,150)
        XCTAssertEqual(session.heartCoverage,1)
        XCTAssertTrue(session.notes.contains { $0.contains("补全") })
    }
    func testSameOriginDuplicateRecordsAreNotLabeledAsTwoDevices() throws {
        let events = WorkoutEventResolver.events([workout("g1",origin:"garmin"),workout("g2",origin:"garmin")])
        XCTAssertEqual(events.count,1)
        XCTAssertFalse(try XCTUnwrap(events.first).notes.contains { $0.contains("双端") })
    }
    func testDeletionReplayAndMissingDistance() {
        var g = workout("g", origin: "garmin", distance: nil)
        let a = workout("a", origin: "apple")
        XCTAssertEqual(WorkoutEventResolver.events([g, a]).first?.selected.distance, 5000)
        XCTAssertEqual(WorkoutEventResolver.events([a]).first?.selected.id, "a")
        g.distance = 4900
        XCTAssertEqual(WorkoutEventResolver.events([a, g]).first?.selected.distance, 4900)
    }
}
