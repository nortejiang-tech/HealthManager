import XCTest
import GRDB
@testable import HealthManager

final class IncrementalProjectionTests: XCTestCase {
    private let bodyType = "HKQuantityTypeIdentifierBodyMass"

    func test_projectsAddedAndDeletedSamplesOlderThanNinetyDays() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let calendar = shanghaiCalendar()
        let date = calendar.date(byAdding: .day, value: -120, to: Date())!
        let dateKey = key(date, calendar: calendar)
        let row = sample(uuid: "old", type: bodyType, value: 71, start: date)

        try commit(store: store, added: [row], calendar: calendar)
        let worker = ProjectionWorker(database: database)
        let inserted = try await worker.runBatch(calendar: calendar)
        XCTAssertTrue(inserted.changedDates.contains(dateKey))
        XCTAssertEqual(try bodyWeight(database, date: dateKey), 71)

        try store.request(types: [bodyType], reason: .observer)
        let claim = try XCTUnwrap(store.claim(type: bodyType, token: UUID()))
        _ = try store.commitPage(.init(
            claim: claim,
            addedRows: [],
            deletedUUIDs: ["old"],
            newAnchorData: Data([2]),
            drained: true,
            calendar: calendar,
            projectionVersion: 1
        ))
        let deleted = try await worker.runBatch(calendar: calendar)
        XCTAssertTrue(deleted.changedDates.contains(dateKey))
        XCTAssertNil(try bodyWeight(database, date: dateKey))
    }

    func test_sleepCrossingMidnightKeepsPublishedSleepOnStartDay() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let calendar = shanghaiCalendar()
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 19, hour: 23
        ))!
        let end = calendar.date(byAdding: .hour, value: 3, to: start)!
        let row = sample(
            uuid: "sleep",
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            value: 1,
            start: start,
            end: end,
            kind: .category,
            unit: "state"
        )
        try commit(store: store, added: [row], calendar: calendar)

        let result = try await ProjectionWorker(database: database).runBatch(calendar: calendar)
        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(try sleepSeconds(database, date: "2026-09-19"), 10_800)
        XCTAssertNil(try sleepSeconds(database, date: "2026-09-20"))
    }

    func test_crossDayWorkoutQueuesBothDaysButPreservesStartDayEnergyRule() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let calendar = shanghaiCalendar()
        let start = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 19, hour: 23, minute: 30
        ))!
        let end = calendar.date(byAdding: .hour, value: 2, to: start)!
        let workout = sample(
            uuid: "workout",
            type: ActivityEnergyCalculator.workoutType,
            value: end.timeIntervalSince(start),
            start: start,
            end: end,
            kind: .workout,
            unit: "second",
            extraJSON: #"{"totalEnergyKcal":450}"#
        )
        try commit(store: store, added: [workout], calendar: calendar)

        let result = try await ProjectionWorker(database: database).runBatch(calendar: calendar)
        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(try activeEnergy(database, date: "2026-09-19"), 450)
        XCTAssertNil(try activeEnergy(database, date: "2026-09-20"))
    }

    func test_dstDaysUseCalendarBoundariesForTwentyThreeAndTwentyFiveHourDays() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 3, day: 8, hour: 12
        ))!
        let fall = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 11, day: 1, hour: 12
        ))!
        try commit(store: store, added: [
            sample(uuid: "spring", type: bodyType, value: 70, start: spring),
            sample(uuid: "fall", type: bodyType, value: 72, start: fall)
        ], calendar: calendar)

        let result = try await ProjectionWorker(database: database).runBatch(calendar: calendar)
        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(try bodyWeight(database, date: "2026-03-08"), 70)
        XCTAssertEqual(try bodyWeight(database, date: "2026-11-01"), 72)
    }

    func test_timezoneChangeRequeuesOnlyRawCoveredDates() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let shanghai = shanghaiCalendar()
        let instant = Date(timeIntervalSince1970: 1_799_996_400)
        try commit(
            store: store,
            added: [sample(uuid: "tz", type: bodyType, value: 73, start: instant)],
            calendar: shanghai
        )
        let worker = ProjectionWorker(database: database)
        _ = try await worker.runBatch(calendar: shanghai)

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let changed = try await worker.runBatch(calendar: losAngeles)
        XCTAssertGreaterThan(changed.processed, 0)
        XCTAssertEqual(try SyncWorkStore(database: database).runtimeState().projectionTimeZone, "America/Los_Angeles")
    }

    func test_generationAddedDuringProjectionIsNotAcknowledged() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let calendar = shanghaiCalendar()
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        try commit(
            store: store,
            added: [sample(uuid: "race", type: bodyType, value: 70, start: date)],
            calendar: calendar
        )
        let worker = ProjectionWorker(database: database)
        let result = try await worker.runBatch(calendar: calendar) {
            try database.write { db in
                try db.execute(sql: "UPDATE sync_projection_work SET generation = generation + 1")
            }
        }

        XCTAssertTrue(result.hasPending)
        XCTAssertFalse(try store.projectionWork().isEmpty)
    }

    func test_noDirtyWorkAndSameValueReprojectionDoNotRewritePublishedRows() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let calendar = shanghaiCalendar()
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let dateKey = key(date, calendar: calendar)
        try commit(
            store: store,
            added: [sample(uuid: "stable", type: bodyType, value: 70, start: date)],
            calendar: calendar
        )
        let worker = ProjectionWorker(database: database)
        _ = try await worker.runBatch(calendar: calendar)
        let computedAt = try bodyComputedAt(database, date: dateKey)

        let empty = try await worker.runBatch(calendar: calendar)
        XCTAssertEqual(empty.processed, 0)

        try database.write { db in
            try db.execute(sql: """
                INSERT INTO sync_projection_work(local_date, time_zone, projection_version, generation)
                VALUES (?, ?, 1, 1)
                """, arguments: [dateKey, calendar.timeZone.identifier])
        }
        let same = try await worker.runBatch(calendar: calendar)
        XCTAssertTrue(same.changedDates.isEmpty)
        XCTAssertEqual(try bodyComputedAt(database, date: dateKey), computedAt)
    }

    func test_noRawEvidencePreservesRestoredAggregateDuringTimezoneInitialization() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO body_metrics_daily(date, weight_kg, computed_at)
                VALUES ('2020-01-01', 68.5, 123)
                """)
        }
        let result = try await ProjectionWorker(database: database).runBatch(calendar: shanghaiCalendar())

        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(try bodyWeight(database, date: "2020-01-01"), 68.5)
        XCTAssertEqual(try bodyComputedAt(database, date: "2020-01-01"), 123)
    }

    func test_timezoneBootstrapScanDoesNotBlockInteractiveMealSave() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let calendar = shanghaiCalendar()
        let scanStarted = expectation(description: "calendar evidence scan started")
        let releaseScan = DispatchSemaphore(value: 0)
        let worker = ProjectionWorker(
            database: database,
            onCalendarEvidenceScanStarted: {
                scanStarted.fulfill()
                _ = releaseScan.wait(timeout: .now() + 5)
            }
        )
        let projectionTask = Task {
            try await worker.runBatch(calendar: calendar)
        }

        await fulfillment(of: [scanStarted], timeout: 1)

        let mealSaved = expectation(description: "interactive meal save completed during scan")
        let store = MealStore(databaseManager: database)
        let saveTask = Task {
            defer { mealSaved.fulfill() }
            return try await store.save(
                meal: MealRecord(
                    id: nil,
                    mealType: .snack,
                    eatenAt: 1_800_000_000,
                    caloriesKcal: nil,
                    proteinG: nil,
                    fatG: nil,
                    carbsG: nil,
                    photoPath: nil,
                    notes: "projection-bootstrap-interactive-write",
                    createdAt: 1_800_000_000,
                    hkSyncId: nil
                ),
                items: []
            )
        }

        await fulfillment(of: [mealSaved], timeout: 1)
        releaseScan.signal()

        let saved = try await saveTask.value
        _ = try await projectionTask.value
        XCTAssertNotNil(saved.meal.id)
        XCTAssertEqual(
            try database.read { db in try MealRecord.fetchCount(db) },
            1
        )
        XCTAssertEqual(
            try SyncWorkStore(database: database).runtimeState().projectionTimeZone,
            calendar.timeZone.identifier
        )
    }

    private func commit(
        store: SyncWorkStore,
        added: [HealthSampleRaw],
        calendar: Calendar
    ) throws {
        let types = Set(added.map(\.hkType))
        for type in types {
            try store.request(types: [type], reason: .observer)
            let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
            _ = try store.commitPage(.init(
                claim: claim,
                addedRows: added.filter { $0.hkType == type },
                deletedUUIDs: [],
                newAnchorData: Data([1]),
                drained: true,
                calendar: calendar,
                projectionVersion: 1
            ))
        }
    }

    private func sample(
        uuid: String,
        type: String,
        value: Double,
        start: Date,
        end: Date? = nil,
        kind: HealthSampleRaw.Kind = .quantity,
        unit: String = "kg",
        extraJSON: String? = nil
    ) -> HealthSampleRaw {
        let end = end ?? start.addingTimeInterval(1)
        return HealthSampleRaw(
            sampleUUID: uuid,
            hkType: type,
            kind: kind,
            value: value,
            unit: unit,
            startAt: Int64(start.timeIntervalSince1970),
            endAt: Int64(end.timeIntervalSince1970),
            sourceName: "fixture",
            sourceBundleId: "fixture.bundle",
            deviceName: nil,
            deviceModel: nil,
            ingestedAt: Int64(Date().timeIntervalSince1970),
            isDeleted: false,
            extraJson: extraJSON,
            sourceOrigin: "unknown"
        )
    }

    private func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func key(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func bodyWeight(_ database: DatabaseManager, date: String) throws -> Double? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT weight_kg FROM body_metrics_daily WHERE date = ?", arguments: [date])
        }
    }

    private func bodyComputedAt(_ database: DatabaseManager, date: String) throws -> Int64? {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT computed_at FROM body_metrics_daily WHERE date = ?", arguments: [date])
        }
    }

    private func sleepSeconds(_ database: DatabaseManager, date: String) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT sleep_seconds FROM activity_metrics_daily WHERE date = ?", arguments: [date])
        }
    }

    private func activeEnergy(_ database: DatabaseManager, date: String) throws -> Double? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT active_energy_kcal FROM activity_metrics_daily WHERE date = ?", arguments: [date])
        }
    }
}
