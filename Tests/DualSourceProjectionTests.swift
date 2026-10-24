import XCTest
import GRDB
@testable import HealthManager

final class DualSourceProjectionTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Asia/Shanghai")!; return c }
    private func epoch(_ day: Int, hour: Int = 0, minute: Int = 0) -> Int64 {
        Int64(calendar.date(from:DateComponents(year:2026,month:10,day:day,hour:hour,minute:minute))!.timeIntervalSince1970)
    }
    private func heart(_ id: String, _ source: String, _ value: Double, _ time: Int64) -> HealthSampleRaw {
        HealthSampleRaw(sampleUUID:id,hkType:TrainingTypes.heart,kind:.quantity,value:value,unit:"count/min",startAt:time,endAt:time,sourceName:source,sourceBundleId:source,deviceName:nil,deviceModel:nil,ingestedAt:time,isDeleted:false,extraJson:nil,sourceOrigin:source)
    }
    private func workout(_ id: String, _ origin: String, start: Int64, end: Int64, energy: Double) -> HealthSampleRaw {
        HealthSampleRaw(sampleUUID:id,hkType:TrainingTypes.workout,kind:.workout,value:Double(end-start),unit:"second",startAt:start,endAt:end,sourceName:origin,sourceBundleId:origin,deviceName:nil,deviceModel:nil,ingestedAt:end,isDeleted:false,extraJson:"{\"activityType\":37,\"totalEnergyKcal\":\(energy)}",sourceOrigin:origin)
    }
    func testDashboardReportAndEvidenceUseGarminOverlapAndAppleGap() async throws {
        let database = DatabaseManager.makeInMemoryForTesting(), t = epoch(23,hour:12)
        try database.write { db in
            for i in 0..<6 {
                try heart("a\(i)","apple",160,t+Int64(i*10)).insert(db)
                if i<3 { try heart("g\(i)","garmin",140,t+Int64(i*10)).insert(db) }
            }
        }
        _ = try await DailyAggregator(database:database).rebuild(dates:["2026-10-23"],calendar:calendar)
        let row = try database.read { try Row.fetchOne($0,sql:"SELECT * FROM activity_metrics_daily WHERE date='2026-10-23'")! }
        // Garmin last read at20 supports through50; Apple then supports through80.
        let expected = (50.0*140 + 30*160)/80
        XCTAssertEqual(try XCTUnwrap(row["avg_hr_bpm"] as Double?),expected,accuracy:0.001)
        let evidence = try XCTUnwrap(row["sources_json"] as String?)
        XCTAssertTrue(evidence.contains("garmin"));XCTAssertTrue(evidence.contains("apple"))
        let report = try await SummaryGenerator(database:database).generateDaily(for:"2026-10-23")
        XCTAssertTrue(report.summaryText?.contains(String(format:"%.0f bpm",expected)) == true)
    }
    func testCrossMidnightAutoDetectionProducesOnePublishedEventAndOneEnergy() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let a = workout("a","apple",start:epoch(23,hour:23,minute:58),end:epoch(24,minute:28),energy:500)
        let g = workout("g","garmin",start:epoch(24,minute:3),end:epoch(24,minute:28),energy:400)
        try database.write { db in
            try a.insert(db);try g.insert(db)
            try WorkoutEventProjection.rebuild(db:db,date:"2026-10-23",start:epoch(23),end:epoch(24)-1)
            try WorkoutEventProjection.rebuild(db:db,date:"2026-10-24",start:epoch(24),end:epoch(25)-1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM workout_events"),1)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT date FROM workout_events"),"2026-10-23")
            XCTAssertEqual(try ActivityEnergyCalculator.dailyActiveEnergyKcal(db:db,start:epoch(23),end:epoch(24)-1,date:"2026-10-23"),500)
            XCTAssertEqual(try ActivityEnergyCalculator.dailyActiveEnergyKcal(db:db,start:epoch(24),end:epoch(25)-1,date:"2026-10-24"),0)
            try db.execute(sql:"UPDATE health_samples_raw SET is_deleted=1 WHERE sample_uuid='g'")
            try WorkoutEventProjection.rebuild(db:db,date:"2026-10-23",start:epoch(23),end:epoch(24)-1)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT id FROM workout_events"),"a")
        }
    }
    func testClearlyPartialGarminDayUsesAppleCompleteTotalWithoutAddition() throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            for (id,origin,begin,finish,value) in [("g","garmin",epoch(23,hour:15),epoch(23,hour:18),2000.0),("a","apple",epoch(23,hour:7),epoch(23,hour:18),8000.0)] {
                try HealthSampleRaw(sampleUUID:id,hkType:"HKQuantityTypeIdentifierStepCount",kind:.quantity,value:value,unit:"count",startAt:begin,endAt:finish,sourceName:origin,sourceBundleId:origin,deviceName:nil,deviceModel:nil,ingestedAt:finish,isDeleted:false,extraJson:nil,sourceOrigin:origin).insert(db)
            }
            let selected = try ActivityEnergyCalculator.dominantCumulativeSum(db:db,hkType:"HKQuantityTypeIdentifierStepCount",start:epoch(23),end:epoch(24)-1)
            XCTAssertEqual(selected.value,8000);XCTAssertEqual(selected.sourceKey,"apple")
            XCTAssertTrue(selected.selectionReason.contains("fallback"))
        }
    }
    func testBridgeCanonicalWorkoutsAndVendorDailyMatchPhoneProjection() throws {
        let database = DatabaseManager.makeInMemoryForTesting(), t = epoch(23,hour:12)
        var vendor = GarminMetricPayload(); vendor.values["primary"] = 40
        try database.write { db in
            try BridgeSource.setEnabled(true,db:db)
            try workout("g","garmin",start:t,end:t+1800,energy:500).insert(db)
            try workout("a","apple",start:t,end:t+1800,energy:550).insert(db)
            try WorkoutEventProjection.rebuild(db:db,date:"2026-10-23",start:epoch(23),end:epoch(24)-1)
            try GarminStore.save(db:db,metric:.stress,date:"2026-10-23",payload:vendor,attemptedAt:Date())
            try BridgeSource.prepare(db,historyStart:Date(timeIntervalSince1970:Double(epoch(23))),timeZone:"Asia/Shanghai")
        }
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite")
        defer { try? FileManager.default.removeItem(at:location) }
        let receiver = try BridgeStore(path:location.path)
        let packets = try database.read { try Row.fetchAll($0,sql:"SELECT manifest,payload FROM bridge_outbox ORDER BY sequence") }
        for row in packets {
            let manifest: Data = row["manifest"], data: Data = row["payload"]
            _ = try receiver.ingest(manifest:JSONDecoder().decode(BridgeManifest.self,from:manifest),payload:data)
        }
        let query = BridgeQuery(store:receiver)
        let response = try query.call("health_workouts",arguments:["from":"2026-10-23","to":"2026-10-23"])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(response.utf8)) as? [String:Any])
        let result = try XCTUnwrap(parsed["result"] as? [String:Any])
        let records = try XCTUnwrap(result["records"] as? [[String:Any]])
        XCTAssertEqual(records.count,1)
        XCTAssertEqual(records.first?["source_bundle_id"] as? String,"garmin")
        XCTAssertEqual((records.first?["contributor_ids"] as? [String])?.count,2)
        XCTAssertNotNil(records.first?["extra_json"])
        XCTAssertEqual(result["pendingProjection"] as? Bool,false)
        let daily = try query.call("health_daily_summary",arguments:["date":"2026-10-23"])
        let dailyObject = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(daily.utf8)) as? [String:Any])
        let dailyResult = try XCTUnwrap(dailyObject["result"] as? [String:Any])
        let vendorRecords = try XCTUnwrap(dailyResult["garmin"] as? [[String:Any]])
        XCTAssertEqual(vendorRecords.count,1)
        XCTAssertEqual(vendorRecords.first?["metric"] as? String,"stress")
        let payloadText = try XCTUnwrap(vendorRecords.first?["payload_json"] as? String)
        let payload = try JSONDecoder().decode(GarminMetricPayload.self,from:Data(payloadText.utf8))
        XCTAssertEqual(payload.primary,40)
    }
    func testBothWorkoutSourcesAreNotAddedToAnExistingEnergyLedger() throws {
        let database = DatabaseManager.makeInMemoryForTesting(), t = epoch(23,hour:12)
        try database.write { db in
            try workout("g","garmin",start:t,end:t+1800,energy:500).insert(db)
            try workout("a","apple",start:t,end:t+1800,energy:550).insert(db)
            let quantity = HealthSampleRaw(sampleUUID:"q",hkType:ActivityEnergyCalculator.activeEnergyType,kind:.quantity,value:450,unit:"kcal",startAt:t,endAt:t+1800,sourceName:"garmin",sourceBundleId:"garmin",deviceName:nil,deviceModel:nil,ingestedAt:t,isDeleted:false,extraJson:nil,sourceOrigin:"garmin")
            try quantity.insert(db)
            XCTAssertEqual(try ActivityEnergyCalculator.dailyActiveEnergyKcal(db:db,start:epoch(23),end:epoch(24)-1,date:"2026-10-23"),450)
        }
    }
}
