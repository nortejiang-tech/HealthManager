import XCTest
import GRDB
@testable import HealthManager

final class WeightContractTests: XCTestCase {
    let key = "2026-10-23"
    func raw(_ id:String, _ hour:Int, _ value:Double, _ source:String, day:Int = 23) -> HealthSampleRaw {
        let d=Calendar.current.date(from:DateComponents(year:2026,month:10,day:day,hour:hour))!
        let t=Int64(d.timeIntervalSince1970)
        return HealthSampleRaw(sampleUUID:id,hkType:"HKQuantityTypeIdentifierBodyMass",kind:.quantity,value:value,unit:"kg",startAt:t,endAt:t,sourceName:source,sourceBundleId:source,deviceName:nil,deviceModel:nil,ingestedAt:t,isDeleted:false,extraJson:nil,sourceOrigin:source == "mijia" ? "xiaomiMijia" : source)
    }
    func testAggregatorReportHistoryAndMacUseSameProjection() async throws {
        let database=DatabaseManager.makeInMemoryForTesting()
        try database.write { db in
            try raw("am",8,70.3,"mijia").insert(db); try raw("garmin",14,76,"garmin").insert(db);try raw("pm",20,72.2,"mijia").insert(db)
            try raw("gOnly",8,60,"garmin",day:22).insert(db)
            try db.execute(sql:"INSERT INTO body_metrics_daily(date,weight_kg,computed_at) VALUES('2026-10-23',76.8,1),('2026-10-22',60,1)")
            try BridgeSource.setEnabled(true,db:db)
        }
        _=try await WeightHistoryRebuilder.run(database:database)
        let daily=try await SummaryGenerator(database:database).generateDaily(for:key)
        XCTAssertTrue(daily.summaryText?.contains("71.25") == true)
        XCTAssertTrue(SummaryGenerator.hasWeightContract(daily.keyFindingsJson))
        try database.read { db in
            XCTAssertEqual(try Double.fetchOne(db,sql:"SELECT weight_kg FROM body_metrics_daily WHERE date=?",arguments:[key]),71.25)
            XCTAssertNil(try Double.fetchOne(db,sql:"SELECT weight_kg FROM body_metrics_daily WHERE date='2026-10-22'"))
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM health_samples_raw"),4)
            XCTAssertEqual(WeightProjection.decode(try String.fetchOne(db,sql:"SELECT sources_json FROM body_metrics_daily WHERE date=?",arguments:[key]))?.strata.count,2)
        }
        try database.write { try BridgeSource.prepare($0,historyStart:WeightProjection.day("2026-10-22")!,timeZone:TimeZone.current.identifier) }
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite").path
        let receiver=try BridgeStore(path:path)
        let packets=try database.read { try Row.fetchAll($0,sql:"SELECT manifest,payload FROM bridge_outbox ORDER BY sequence") }
        for row in packets { let m:Data=row["manifest"];let p:Data=row["payload"];_=try receiver.ingest(manifest:JSONDecoder().decode(BridgeManifest.self,from:m),payload:p) }
        let json=try BridgeQuery(store:receiver).call("health_metric_history",arguments:["metric":"weight","from":"2026-10-22","to":key])
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        let result=try XCTUnwrap(object["result"] as? [String:Any]);let values=try XCTUnwrap(result["values"] as? [[String:Any]])
        XCTAssertTrue(values[0]["value"] is NSNull);XCTAssertEqual(values[1]["value"] as? Double,71.25)
        XCTAssertTrue((result["method"] as? String)?.contains(WeightAggregationPolicy.version) == true)
        let rawJSON = try BridgeQuery(store:receiver).call("health_records",arguments:["category":"health_samples_raw","from":key,"to":key,"type":"HKQuantityTypeIdentifierBodyMass"])
        let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String:Any])
        let rawRows = try XCTUnwrap((rawObject["result"] as? [String:Any])?["records"] as? [[String:Any]])
        XCTAssertEqual(rawRows.filter { $0["weight_exclusion_reason"] as? String == "garmin_manual_weight" }.count, 1)
        XCTAssertEqual(rawRows.filter { $0["weight_statistic_eligible"] as? Bool == true }.count, 2)
        let again = try await WeightHistoryRebuilder.run(database:database)
        XCTAssertEqual(again,0)
    }
    func testWeeklyMeanWeightsValidDaysEquallyAndInvalidatesOldLLM() async throws {
        let db=DatabaseManager.makeInMemoryForTesting()
        try db.write { d in
            for i in 0..<5 {try raw("a\(i)",8,76,"mijia",day:19).insert(d)}
            try raw("b",20,80,"mijia",day:20).insert(d)
            try raw("g",8,55,"garmin",day:21).insert(d)
            try d.execute(sql:"INSERT INTO weekly_summaries(week_start_date,summary_text,findings_json,generated_at,llm_text) VALUES('2026-10-19','old','{}',1,'old opinion')")
        }
        let summary=try await SummaryGenerator(database:db).currentWeekly(weekStart:"2026-10-19")
        XCTAssertTrue(summary?.summaryText?.contains("78.00") == true)
        XCTAssertNil(summary?.llmText)
        let archived = try db.read { try String.fetchOne($0,sql:"SELECT original_json FROM summary_contract_archive WHERE kind='weekly'") }
        XCTAssertTrue(archived?.contains("old opinion") == true)
        let data=try XCTUnwrap(summary?.findingsJson?.data(using:.utf8));let findings=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(findings["weightValidDays"] as? Int,2);XCTAssertEqual(findings["weightKg"] as? Double,78)
    }
    func testBackupRoundTripIncludesArchiveAndWeightEvidence() async throws {
        let source=DatabaseManager.makeInMemoryForTesting()
        try source.write { db in
            try db.execute(sql:"INSERT INTO summary_contract_archive VALUES('daily','2026-10-23','original text',1)")
            try raw("x",8,76,"mijia").insert(db)
        }
        _=try await WeightHistoryRebuilder.run(database:source)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest=try await BackupExporter(database:source).export(to:dir)
        XCTAssertEqual(manifest.formatVersion,7)
        let target=DatabaseManager.makeInMemoryForTesting();_=try await BackupImporter(database:target).importPackage(from:dir)
        try target.read { db in
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT original_json FROM summary_contract_archive"),"original text")
            XCTAssertEqual(WeightProjection.decode(try String.fetchOne(db,sql:"SELECT sources_json FROM body_metrics_daily WHERE date=?",arguments:[key]))?.mean,76)
        }
    }
}
