import XCTest
import GRDB
@testable import HealthManager

final class WorkoutRecordChoiceTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    var start: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))! }
    func workout(_ id: String, _ origin: String, seconds: Double = 1800, distance: Double? = 4000, energy: Double? = 400) -> TrainingSample {
        TrainingSample(id: id, type: TrainingTypes.workout, value: seconds, start: start, end: start.addingTimeInterval(seconds), source: origin == "garmin" ? "com.garmin.connect" : "com.apple.health", sourceName: origin, origin: origin, ingestedAt: start, activityType: 37, duration: seconds, distance: distance, energyKcal: energy)
    }
    func choice(_ selected: String?, time: Double = 1, members: [String] = ["g","a"]) -> WorkoutRecordChoice {
        WorkoutRecordChoice(id: "decision-\(time)", selectedID: selected, memberIDs: members, updatedAt: time)
    }
    func raw(_ sample: TrainingSample) throws -> HealthSampleRaw {
        let extra: [String:Any] = ["duration": sample.duration ?? 0,"activityType":37,"totalDistanceMeters":sample.distance as Any? ?? NSNull(),"totalEnergyKcal":sample.energyKcal as Any? ?? NSNull()]
        return HealthSampleRaw(sampleUUID: sample.id, hkType: sample.type, kind: .workout, value: sample.value, unit: "second", startAt: Int64(sample.start.timeIntervalSince1970), endAt: Int64(sample.end.timeIntervalSince1970), sourceName: sample.sourceName, sourceBundleId: sample.source, deviceName: nil, deviceModel: nil, ingestedAt: Int64(sample.ingestedAt.timeIntervalSince1970), isDeleted: false, extraJson: String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self), sourceOrigin: sample.origin)
    }
    func seed(_ db: DatabaseManager) throws {
        try db.write { d in
            try raw(workout("g","garmin")).insert(d)
            try raw(workout("a","apple",distance:5000,energy:300)).insert(d)
        }
    }
    func testManualRecordKeepsWindowAndValuesWhileFillingOnlyMissing() throws {
        let g = workout("g","garmin",seconds:1500,distance:nil,energy:0)
        let a = workout("a","apple",distance:5000,energy:300)
        let auto = try XCTUnwrap(WorkoutEventResolver.events([a,g]).first)
        XCTAssertEqual(auto.selected.duration,1800)
        let manual = try XCTUnwrap(WorkoutEventResolver.events([a,g],choices:[choice("g")]).first)
        XCTAssertTrue(manual.isManuallySelected)
        XCTAssertEqual(manual.selected.duration,1500)
        XCTAssertEqual(manual.selected.distance,5000)
        XCTAssertEqual(manual.selected.energyKcal,0)
        XCTAssertFalse(manual.notes.contains { $0.contains("时长/距离") })
        var zero = g; zero.distance=0
        XCTAssertEqual(WorkoutEventResolver.events([a,zero],choices:[choice("g")]).first?.selected.distance,0)
    }
    func testManualAppleHeartWinsOverlapAndGarminFillsGap() throws {
        func hearts(_ origin: String, seconds: Double, value: Double) -> [TrainingSample] {
            stride(from:0.0,to:seconds,by:10).map { t in
                TrainingSample(id:"\(origin)-\(t)", type:TrainingTypes.heart,value:value,start:start.addingTimeInterval(t),end:start.addingTimeInterval(t),source:origin == "apple" ? "com.apple.health" : "com.garmin.connect",sourceName:origin,origin:origin,ingestedAt:start)
            }
        }
        let input = [workout("g","garmin"),workout("a","apple",distance:5000)] + hearts("garmin",seconds:1800,value:120) + hearts("apple",seconds:1180,value:150)
        let snapshot = TrainingCalculator.snapshot(samples:input,now:start.addingTimeInterval(3600),calendar:calendar,choices:[choice("a")])
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(snapshot.sessions.count,1); XCTAssertEqual(session.id,"a"); XCTAssertEqual(session.distanceKm,5)
        XCTAssertEqual(session.heartCoverage,1,accuracy:0.001)
        XCTAssertEqual(try XCTUnwrap(session.averageHeartRate),(150*1200.0+120*600.0)/1800,accuracy:0.001)
        XCTAssertTrue(session.notes.contains { $0.contains("优先所选来源") })
        XCTAssertEqual(TrainingCalculator.recordDetail(id:"g",samples:input,now:start.addingTimeInterval(3600),calendar:calendar,choices:[choice("a")])?.id,"a")
    }
    func testLatestDecisionResetAndMissingRecordRetainEvidence() throws {
        let records=[workout("g","garmin"),workout("a","apple")]
        XCTAssertEqual(WorkoutEventResolver.events(records,choices:[choice("a")]).first?.selected.id,"a")
        XCTAssertEqual(WorkoutEventResolver.events(records,choices:[choice("a"),choice(nil,time:2)]).first?.selected.id,"g")
        let missing=try XCTUnwrap(WorkoutEventResolver.events([records[0]],choices:[choice("a")]).first)
        XCTAssertFalse(missing.isManuallySelected); XCTAssertEqual(missing.choice?.selectedID,"a")
        XCTAssertTrue(missing.notes.contains { $0.contains("不可用") })
        XCTAssertEqual(WorkoutEventResolver.events(records.reversed(),choices:[choice("a")]).first?.selected.id,"a")
        XCTAssertNil(WorkoutEventResolver.events(records,choices:[choice("a",time:.nan)]).first?.choice)
        var invalid=records[1]; invalid.duration = .infinity
        XCTAssertEqual(WorkoutEventResolver.events([records[0],invalid],choices:[choice("a")]).first?.selected.id,"g")
    }
    func testStoredChoiceSurvivesReplayAndInvalidSaveDoesNotMutate() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();try seed(db)
        let dates=try await WorkoutChoiceStore.save(database:db,recordID:"g",selectedID:"a",now:start,calendar:calendar)
        XCTAssertEqual(dates.count,3)
        try db.read { d in
            XCTAssertEqual(try WorkoutChoiceStore.context(db:d,recordID:"g").event.selected.id,"a")
            XCTAssertEqual(try Int.fetchOne(d,sql:"SELECT COUNT(*) FROM sync_projection_work"),3)
        }
        do { _=try await WorkoutChoiceStore.save(database:db,recordID:"g",selectedID:"not-a-member"); XCTFail("must reject") } catch { }
        XCTAssertEqual(try db.read { try WorkoutChoiceStore.load(db:$0).count },1)
        _=try await WorkoutChoiceStore.save(database:db,recordID:"g",selectedID:nil,now:start,calendar:calendar)
        XCTAssertEqual(try db.read { try WorkoutChoiceStore.context(db:$0,recordID:"a").event.selected.id },"g")
        let snapshot=try await TrainingSnapshotLoader.load(database:db,now:start.addingTimeInterval(3600),calendar:calendar)
        XCTAssertEqual(snapshot.sessions.first?.id,"g")
    }
    func testSelectionUpdatesEnergyReportsCanonicalListAndMacExactlyOnce() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();try seed(db)
        try db.write { d in
            for (id,value,begin,end) in [("outside",200.0,start.addingTimeInterval(-3600),start),("during",400.0,start,start.addingTimeInterval(1800))] {
                var sample=try raw(workout(id,"garmin")); sample.hkType=ActivityEnergyCalculator.activeEnergyType;sample.kind = .quantity;sample.value=value;sample.unit="kcal";sample.startAt=Int64(begin.timeIntervalSince1970);sample.endAt=Int64(end.timeIntervalSince1970);try sample.insert(d)
            }
            try BridgeSource.setEnabled(true,db:d)
        }
        let generator=SummaryGenerator(database:db)
        _=try await generator.generateDaily(for:"2026-10-25");_=try await generator.generateWeekly(weekStart:"2026-10-19")
        try await WorkoutChoiceStore.apply(database:db,recordID:"g",selectedID:"a")
        try db.read { d in
            XCTAssertEqual(try Double.fetchOne(d,sql:"SELECT active_energy_kcal FROM activity_metrics_daily WHERE date='2026-10-25'"),500)
            let raw=try HealthSampleRaw.fetchAll(d,sql:"SELECT * FROM health_samples_raw WHERE hk_type=?",arguments:[TrainingTypes.workout])
            let rows=ActivityWorkoutRow.canonical(raw,choices:try WorkoutChoiceStore.load(db:d))
            XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.id,"a");XCTAssertEqual(rows.first?.energyKcal,300)
            XCTAssertFalse(SummaryGenerator.hasPendingWorkoutSelection(try String.fetchOne(d,sql:"SELECT key_findings_json FROM daily_summaries")))
            XCTAssertTrue(try String.fetchOne(d,sql:"SELECT summary_text FROM daily_summaries")?.contains("500 kcal") == true)
        }
        try db.write { try BridgeSource.prepare($0,historyStart:start.addingTimeInterval(-86400),now:start.addingTimeInterval(3600)) }
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite").path
        let receiver=try BridgeStore(path:path)
        for row in try db.read({ try Row.fetchAll($0,sql:"SELECT manifest,payload FROM bridge_outbox ORDER BY sequence") }) {
            let m:Data=row["manifest"],p:Data=row["payload"];_=try receiver.ingest(manifest:JSONDecoder().decode(BridgeManifest.self,from:m),payload:p)
        }
        let result=try BridgeQuery(store:receiver).call("health_workouts",arguments:["from":"2026-10-25","to":"2026-10-25"])
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.utf8)) as? [String:Any])
        let rows=try XCTUnwrap((object["result"] as? [String:Any])?["records"] as? [[String:Any]])
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?["selection_mode"] as? String,"manual");XCTAssertEqual(rows.first?["sample_uuid"] as? String,"a")
    }
    func testBackupRestoresChoiceAndExplicitAutomaticDecision() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();try seed(db)
        try await WorkoutChoiceStore.apply(database:db,recordID:"g",selectedID:"a")
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest=try await BackupExporter(database:db).export(to:url);XCTAssertEqual(manifest.formatVersion,7)
        XCTAssertTrue(manifest.files.contains { $0.file=="workout_record_choices.jsonl" })
        let restored=DatabaseManager.makeInMemoryForTesting();_=try await BackupImporter(database:restored).importPackage(from:url);try seed(restored)
        XCTAssertEqual(try restored.read { try WorkoutChoiceStore.context(db:$0,recordID:"g").event.selected.id },"a")
        try await WorkoutChoiceStore.apply(database:restored,recordID:"a",selectedID:nil)
        _=try await BackupImporter(database:restored).importPackage(from:url)
        XCTAssertEqual(try restored.read { try WorkoutChoiceStore.context(db:$0,recordID:"a").event.selected.id },"g")
        XCTAssertEqual(try restored.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM workout_events") },1,"older backup must not resurrect a second canonical event")
        XCTAssertEqual(try restored.read { try String.fetchOne($0,sql:"SELECT id FROM workout_events") },"g")
    }
    func testStaleAggregationCannotOverwriteNewChoiceAndLeavesDirtyWork() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();try seed(db)
        _=try await WorkoutChoiceStore.save(database:db,recordID:"g",selectedID:"a",now:start)
        let aggregator=DailyAggregator(database:db,afterSnapshotBeforeWrite:{
            try db.write { d in try d.execute(sql:"UPDATE workout_record_choices SET updated_at=updated_at+1") }
        })
        do { _=try await aggregator.rebuild(dates:["2026-10-25"],calendar:calendar);XCTFail("stale revision must be rejected") } catch { }
        XCTAssertEqual(try db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sync_projection_work") },3)
        XCTAssertNil(try db.read { try String.fetchOne($0,sql:"SELECT payload_json FROM workout_events") })
        _=try await ProjectionWorker(database:db).runBatch(calendar:calendar)
        XCTAssertTrue(try db.read { try String.fetchOne($0,sql:"SELECT payload_json FROM workout_events")?.contains("\"selection_mode\":\"manual\"") == true })
    }
    func testLateContributorAndResetCannotResurrectOlderDecision() {
        let g=workout("g","garmin"),a=workout("a","apple"),late=workout("late","apple",distance:6000)
        let chosen=choice("a",time:1,members:["g","a"])
        XCTAssertEqual(WorkoutEventResolver.events([g,a,late],choices:[chosen]).first?.selected.id,"a")
        XCTAssertEqual(WorkoutEventResolver.events([late,a,g],choices:[chosen,choice(nil,time:2,members:["a","late"])]).first?.selected.id,"g")
    }
    func testManualSaveDoesNotWaitForUnrelatedProjectionBacklog() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();try seed(db)
        try db.write { d in
            try d.execute(sql:"INSERT INTO sync_projection_work(local_date,time_zone,projection_version,generation) VALUES('2026-11-10',?,1,1)",arguments:[Calendar.current.timeZone.identifier])
        }
        try await WorkoutChoiceStore.apply(database:db,recordID:"g",selectedID:"a")
        XCTAssertEqual(try db.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sync_projection_work WHERE local_date='2026-11-10'") },1)
        XCTAssertEqual(try db.read { try String.fetchOne($0,sql:"SELECT id FROM workout_events") },"a")
    }
    func testEarlierManuallySelectedEventIsProjectedWithoutLegacyDuplicate() async throws {
        let db=DatabaseManager.makeInMemoryForTesting()
        try db.write { d in
            for sample in [workout("g","garmin"),workout("a","apple")] {
                var old=try raw(sample);old.startAt-=3*86400;old.endAt-=3*86400;old.ingestedAt=old.startAt;try old.insert(d)
            }
            try BridgeSource.setEnabled(true,db:d)
        }
        try await WorkoutChoiceStore.apply(database:db,recordID:"g",selectedID:"a")
        XCTAssertEqual(try db.read { try String.fetchOne($0,sql:"SELECT date FROM workout_events") },"2026-10-22")
        try db.write { try BridgeSource.prepare($0,historyStart:start.addingTimeInterval(-5*86400),now:start) }
        let receiver=try BridgeStore(path:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite").path)
        for row in try db.read({try Row.fetchAll($0,sql:"SELECT manifest,payload FROM bridge_outbox ORDER BY sequence")}) {
            let m:Data=row["manifest"],p:Data=row["payload"];_=try receiver.ingest(manifest:JSONDecoder().decode(BridgeManifest.self,from:m),payload:p)
        }
        let json=try BridgeQuery(store:receiver).call("health_workouts",arguments:["from":"2026-10-22","to":"2026-10-22"])
        let data=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        let records=try XCTUnwrap((data["result"] as? [String:Any])?["records"] as? [[String:Any]])
        XCTAssertEqual(records.count,1);XCTAssertEqual(records.first?["sample_uuid"] as? String,"a")
    }
}
