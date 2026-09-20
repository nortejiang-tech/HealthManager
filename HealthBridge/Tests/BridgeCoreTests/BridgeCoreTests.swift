import XCTest
import GRDB
import Darwin
@testable import BridgeCore

final class BridgeCoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("bridge-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func source() throws -> DatabasePool {
        let pool=try DatabasePool(path:root.appendingPathComponent("source-\(UUID()).sqlite").path)
        try pool.write { db in
            for spec in BridgeWire.tables {
                if spec.name == "health_samples_raw" {
                    try db.execute(sql:"CREATE TABLE health_samples_raw(sample_uuid TEXT PRIMARY KEY,hk_type TEXT,start_at REAL,end_at REAL,value REAL,is_deleted INTEGER,extra_json TEXT,source_bundle_id TEXT,source_origin TEXT)")
                } else if spec.name == "meal_records" {
                    try db.execute(sql:"CREATE TABLE meal_records(id INTEGER PRIMARY KEY,eaten_at REAL,notes TEXT,photo_path TEXT)")
                } else { try db.execute(sql:"CREATE TABLE \(spec.name)(\(spec.key) TEXT PRIMARY KEY,value REAL)") }
            }
            try BridgeSource.migrate(db);try BridgeSource.setEnabled(true,db:db)
        }
        return pool
    }
    func prepare(_ pool:DatabasePool, now:Double=100) throws {
        try pool.write { try BridgeSource.prepare($0,historyStart:Date(timeIntervalSince1970:0),now:Date(timeIntervalSince1970:now),timeZone:"Asia/Shanghai") }
    }
    func packets(_ pool:DatabasePool) throws -> [(BridgeManifest,Data)] {
        try pool.read { db in try Row.fetchAll(db,sql:"SELECT * FROM bridge_outbox ORDER BY sequence").map { r in
            let m:Data=r["manifest"]; let p:Data=r["payload"];return (try JSONDecoder().decode(BridgeManifest.self,from:m),p)
        } }
    }
    func receiver() throws -> BridgeStore { try BridgeStore(path:root.appendingPathComponent("receiver.sqlite").path) }
    func nutritionSource() throws -> DatabasePool {
        let pool = try DatabasePool(path: root.appendingPathComponent("nutrition-\(UUID()).sqlite").path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE health_samples_raw(sample_uuid TEXT PRIMARY KEY,hk_type TEXT,start_at REAL,end_at REAL,value REAL,is_deleted INTEGER,extra_json TEXT,source_bundle_id TEXT,source_origin TEXT)")
            try db.execute(sql: "CREATE TABLE meal_records(id INTEGER PRIMARY KEY,meal_type TEXT,eaten_at REAL,calories_kcal REAL,protein_g REAL,fat_g REAL,carbs_g REAL,notes TEXT,photo_path TEXT,created_at REAL)")
            try db.execute(sql: "CREATE TABLE meal_items(id TEXT PRIMARY KEY,value REAL)")
            try db.execute(sql: "CREATE TABLE medication_plans(id TEXT PRIMARY KEY,value REAL)")
            try db.execute(sql: "CREATE TABLE medication_logs(id TEXT PRIMARY KEY,value REAL)")
            try db.execute(sql: "CREATE TABLE activity_metrics_daily(date TEXT PRIMARY KEY,active_energy_kcal REAL,basal_energy_kcal REAL)")
            try db.execute(sql: "CREATE TABLE body_metrics_daily(date TEXT PRIMARY KEY,value REAL)")
            try db.execute(sql: "CREATE TABLE data_quality_daily(date TEXT PRIMARY KEY,value REAL)")
            try BridgeSource.migrate(db)
            try BridgeSource.setEnabled(true, db: db)
        }
        return pool
    }
    func activeCount(_ store:BridgeStore) throws -> Int {
        try store.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM replica WHERE epoch=(SELECT active_epoch FROM receiver_state WHERE id=1)")! }
    }
    func testSnapshotIdempotencyAndPrivacy() throws {
        let p=try source();try p.write { try $0.execute(sql:"INSERT INTO meal_records VALUES(1,100,'dinner','private.jpg')") };try prepare(p)
        let s=try receiver();let (m,d)=try packets(p)[0]
        XCTAssertFalse(String(decoding:d,as:UTF8.self).contains("photo_path"))
        _=try s.ingest(manifest:m,payload:d);_=try s.ingest(manifest:m,payload:d)
        XCTAssertEqual(try activeCount(s),1)
    }
    func testSnapshotHiddenUntilFinalAndGapRecovery() throws {
        let p=try source();try p.write { db in for i in 0..<1100 { try db.execute(sql:"INSERT INTO meal_records VALUES(?,100,'x',NULL)",arguments:[i]) } };try prepare(p)
        let b=try packets(p);XCTAssertEqual(b.count,2);let s=try receiver()
        XCTAssertThrowsError(try s.ingest(manifest:b[1].0,payload:b[1].1))
        _=try s.ingest(manifest:b[0].0,payload:b[0].1);XCTAssertEqual(try activeCount(s),0)
        _=try s.ingest(manifest:b[1].0,payload:b[1].1);XCTAssertEqual(try activeCount(s),1100)
    }
    func testEditDeleteAndTransactionRollbackCaptured() throws {
        let p=try source();try p.write { try $0.execute(sql:"INSERT INTO meal_records VALUES(1,100,'before',NULL)") };try prepare(p)
        let s=try receiver();for (m,d) in try packets(p) { _=try s.ingest(manifest:m,payload:d) }
        XCTAssertThrowsError(try p.write { db in try db.execute(sql:"UPDATE meal_records SET notes='bad'");throw BridgeError.invalid("rollback") })
        XCTAssertEqual(try p.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM bridge_changes") },0)
        try p.write { try $0.execute(sql:"UPDATE meal_records SET notes='after'") };try prepare(p)
        let edit=try packets(p).last!;_=try s.ingest(manifest:edit.0,payload:edit.1)
        let text=try BridgeQuery(store:s).call("health_meals",arguments:["from":"1970-01-01","to":"1970-01-01"]);XCTAssertTrue(text.contains("after"));XCTAssertFalse(text.contains("before"))
        try p.write { try $0.execute(sql:"DELETE FROM meal_records") };try prepare(p)
        let del=try packets(p).last!;_=try s.ingest(manifest:del.0,payload:del.1);XCTAssertEqual(try activeCount(s),0)
    }
    func testChecksumFailurePreservesReplica() throws {
        let p=try source();try prepare(p);let s=try receiver();let (m,d)=try packets(p)[0]
        XCTAssertThrowsError(try s.ingest(manifest:m,payload:d+Data("x".utf8)));XCTAssertEqual(try activeCount(s),0)
        _=try s.ingest(manifest:m,payload:d)
    }
    func testNewEpochAtomicSwitchAndOldEpochReplay() throws {
        let p=try source();try p.write { try $0.execute(sql:"INSERT INTO meal_records VALUES(1,100,'old',NULL)") };try prepare(p)
        let s=try receiver();let old=try packets(p)[0];_=try s.ingest(manifest:old.0,payload:old.1)
        try p.write { db in try BridgeSource.reset(db);try db.execute(sql:"DELETE FROM meal_records") };try prepare(p,now:200)
        for (m,d) in try packets(p) { _=try s.ingest(manifest:m,payload:d) }
        _=try s.ingest(manifest:old.0,payload:old.1);XCTAssertEqual(try activeCount(s),0)
    }
    func testFutureVersionAndForeignSourceRejected() throws {
        let p=try source();try prepare(p);let s=try receiver();let (m,d)=try packets(p)[0]
        var bad=m;bad.version=2;XCTAssertThrowsError(try s.ingest(manifest:bad,payload:d));_=try s.ingest(manifest:m,payload:d)
        let q=try source();try prepare(q,now:200);let foreign=try packets(q)[0];XCTAssertThrowsError(try s.ingest(manifest:foreign.0,payload:foreign.1))
    }
    func testManifestBeforePayloadAndReceiptRecovery() throws {
        let p=try source();try prepare(p);let s=try receiver();let (m,_)=try packets(p)[0]
        let sync=root.appendingPathComponent("sync");_=try BridgeSource.publish(pool:p,root:sync)
        let payload=sync.appendingPathComponent("batches/\(BridgeWire.folder(m))/records.jsonl")
        let saved=try Data(contentsOf:payload);try FileManager.default.removeItem(at:payload)
        XCTAssertEqual(try s.scan(root:sync),0);try saved.write(to:payload)
        XCTAssertEqual(try s.scan(root:sync),1)
        let receipt=sync.appendingPathComponent("receipts/\(BridgeWire.folder(m)).json")
        try FileManager.default.removeItem(at:receipt);XCTAssertEqual(try s.scan(root:sync),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:receipt.path))
        XCTAssertTrue(try BridgeSource.publish(pool:p,root:sync).contains("Mac 已入库"))
    }
    func testDisabledWritesRequireFreshSnapshotOnReenable() throws {
        let p=try source();try prepare(p)
        try p.write { db in try BridgeSource.setEnabled(false,db:db);try db.execute(sql:"INSERT INTO meal_records VALUES(1,100,'offline',NULL)");try BridgeSource.setEnabled(true,db:db) }
        try prepare(p,now:200);let s=try receiver();for (m,d) in try packets(p) { _=try s.ingest(manifest:m,payload:d) };XCTAssertEqual(try activeCount(s),1)
    }
    func testUnknownValuePaginationAndReadOnlyTools() throws {
        let p=try source();try prepare(p);let s=try receiver();for (m,d) in try packets(p) { _=try s.ingest(manifest:m,payload:d) }
        let q=BridgeQuery(store:s)
        let data=Data(try q.call("health_metric_history",arguments:["metric":"weight","from":"1970-01-01","to":"1970-01-03"]).utf8)
        let obj=try JSONSerialization.jsonObject(with:data) as! [String:Any];let result=obj["result"] as! [String:Any]
        XCTAssertEqual(result["missingDays"] as? Int,3);XCTAssertEqual(result["validDays"] as? Int,0)
        XCTAssertThrowsError(try q.call("run_sql"));XCTAssertThrowsError(try q.call("health_records",arguments:["limit":1001]))
    }
    func testDailyNutritionAndEnergyBalanceReadContract() throws {
        let p = try nutritionSource()
        try p.write { db in
            try db.execute(sql: "INSERT INTO meal_records VALUES(1,'breakfast',100,400,20,10,50,'',NULL,100)")
            try db.execute(sql: "INSERT INTO meal_records VALUES(2,'dinner',200,600,30,20,70,'',NULL,100)")
            try db.execute(sql: "INSERT INTO activity_metrics_daily VALUES('1970-01-01',500,1500)")
        }
        try prepare(p)
        let s = try receiver()
        for (manifest, payload) in try packets(p) { _ = try s.ingest(manifest: manifest, payload: payload) }
        let q = BridgeQuery(store: s)

        let summaryData = Data(try q.call("health_daily_summary", arguments: ["date":"1970-01-01"]).utf8)
        let summary = try JSONSerialization.jsonObject(with: summaryData) as! [String: Any]
        let result = summary["result"] as! [String: Any]
        let nutrition = result["nutrition"] as! [String: Any]
        XCTAssertEqual(nutrition["mealCount"] as? Int, 2)
        XCTAssertEqual(nutrition["calorieStatus"] as? String, "complete")
        XCTAssertEqual(nutrition["calorieIntakeKcal"] as? Double, 1000)
        XCTAssertEqual(nutrition["proteinG"] as? Double, 50)
        XCTAssertEqual(nutrition["fatG"] as? Double, 30)
        XCTAssertEqual(nutrition["carbsG"] as? Double, 120)
        let balance = result["energyBalance"] as! [String: Any]
        XCTAssertEqual(balance["status"] as? String, "complete")
        XCTAssertEqual(balance["totalEnergyExpenditureKcal"] as? Double, 2000)
        XCTAssertEqual(balance["calorieDeficitKcal"] as? Double, 1000)

        let historyData = Data(try q.call("health_metric_history", arguments: ["metric":"calorie_deficit","from":"1970-01-01","to":"1970-01-02"]).utf8)
        let history = try JSONSerialization.jsonObject(with: historyData) as! [String: Any]
        let historyResult = history["result"] as! [String: Any]
        let values = historyResult["values"] as! [[String: Any]]
        XCTAssertEqual(values[0]["value"] as? Double, 1000)
        XCTAssertTrue(values[1]["value"] is NSNull)
        XCTAssertEqual(historyResult["validDays"] as? Int, 1)
        XCTAssertEqual(historyResult["missingDays"] as? Int, 1)
    }
    func testDailyNutritionMarksUnknownCaloriesAndDeficitAsUnknown() throws {
        let p = try nutritionSource()
        try p.write { db in
            try db.execute(sql: "INSERT INTO meal_records VALUES(1,'breakfast',100,400,20,10,50,'',NULL,100)")
            try db.execute(sql: "INSERT INTO meal_records VALUES(2,'dinner',200,NULL,30,20,70,'',NULL,100)")
            try db.execute(sql: "INSERT INTO activity_metrics_daily VALUES('1970-01-01',500,1500)")
        }
        try prepare(p)
        let s = try receiver()
        for (manifest, payload) in try packets(p) { _ = try s.ingest(manifest: manifest, payload: payload) }
        let data = Data(try BridgeQuery(store: s).call("health_daily_summary", arguments: ["date":"1970-01-01"]).utf8)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let result = object["result"] as! [String: Any]
        let nutrition = result["nutrition"] as! [String: Any]
        XCTAssertEqual(nutrition["calorieStatus"] as? String, "incomplete")
        XCTAssertTrue(nutrition["calorieIntakeKcal"] is NSNull)
        let balance = result["energyBalance"] as! [String: Any]
        XCTAssertEqual(balance["status"] as? String, "incomplete_calorie_intake")
        XCTAssertTrue(balance["calorieDeficitKcal"] is NSNull)
    }
    func testDailyNutritionKeepsNoMealsAndInvalidEnergyUnknown() throws {
        let noMeals = try nutritionSource()
        try noMeals.write { db in
            try db.execute(sql: "INSERT INTO activity_metrics_daily VALUES('1970-01-01',500,1500)")
        }
        try prepare(noMeals)
        let noMealsReceiver = try receiver()
        for (manifest, payload) in try packets(noMeals) { _ = try noMealsReceiver.ingest(manifest: manifest, payload: payload) }
        let noMealsData = Data(try BridgeQuery(store: noMealsReceiver).call("health_daily_summary", arguments: ["date":"1970-01-01"]).utf8)
        let noMealsObject = try JSONSerialization.jsonObject(with: noMealsData) as! [String: Any]
        let noMealsResult = noMealsObject["result"] as! [String: Any]
        let noMealsNutrition = noMealsResult["nutrition"] as! [String: Any]
        XCTAssertEqual(noMealsNutrition["calorieStatus"] as? String, "no_meals")
        XCTAssertTrue(noMealsNutrition["calorieIntakeKcal"] is NSNull)
        let noMealsBalance = noMealsResult["energyBalance"] as! [String: Any]
        XCTAssertEqual(noMealsBalance["totalEnergyExpenditureKcal"] as? Double, 2000)
        XCTAssertTrue(noMealsBalance["calorieDeficitKcal"] is NSNull)
        XCTAssertEqual(noMealsBalance["status"] as? String, "no_meals")

        let invalidEnergy = try nutritionSource()
        try invalidEnergy.write { db in
            try db.execute(sql: "INSERT INTO meal_records VALUES(1,'breakfast',100,400,20,10,50,'',NULL,100)")
            try db.execute(sql: "INSERT INTO activity_metrics_daily VALUES('1970-01-01',-1,1500)")
        }
        try prepare(invalidEnergy)
        let invalidReceiver = try BridgeStore(path: root.appendingPathComponent("invalid-energy-receiver.sqlite").path)
        for (manifest, payload) in try packets(invalidEnergy) { _ = try invalidReceiver.ingest(manifest: manifest, payload: payload) }
        let invalidData = Data(try BridgeQuery(store: invalidReceiver).call("health_daily_summary", arguments: ["date":"1970-01-01"]).utf8)
        let invalidObject = try JSONSerialization.jsonObject(with: invalidData) as! [String: Any]
        let invalidResult = invalidObject["result"] as! [String: Any]
        let invalidBalance = invalidResult["energyBalance"] as! [String: Any]
        XCTAssertEqual(invalidBalance["status"] as? String, "invalid_energy_inputs")
        XCTAssertTrue(invalidBalance["activeEnergyKcal"] is NSNull)
        XCTAssertTrue(invalidBalance["totalEnergyExpenditureKcal"] is NSNull)
        XCTAssertTrue(invalidBalance["calorieDeficitKcal"] is NSNull)

        let missingFirst = try nutritionSource()
        try missingFirst.write { db in
            try db.execute(sql: "INSERT INTO meal_records VALUES(1,'breakfast',100,400,20,10,50,'',NULL,100)")
            try db.execute(sql: "INSERT INTO activity_metrics_daily VALUES('1970-01-01',NULL,-1)")
        }
        try prepare(missingFirst)
        let missingFirstReceiver = try BridgeStore(path: root.appendingPathComponent("missing-first-receiver.sqlite").path)
        for (manifest, payload) in try packets(missingFirst) { _ = try missingFirstReceiver.ingest(manifest: manifest, payload: payload) }
        let missingFirstData = Data(try BridgeQuery(store: missingFirstReceiver).call("health_daily_summary", arguments: ["date":"1970-01-01"]).utf8)
        let missingFirstObject = try JSONSerialization.jsonObject(with: missingFirstData) as! [String: Any]
        let missingFirstResult = missingFirstObject["result"] as! [String: Any]
        let missingFirstBalance = missingFirstResult["energyBalance"] as! [String: Any]
        XCTAssertEqual(missingFirstBalance["status"] as? String, "missing_active_energy")
    }
    func testSleepOverlapAndMissingStages() throws {
        let p=try source()
        // UTC 1970-01-01 18:00 lies in wake-day Jan 2 Shanghai night.
        try p.write { db in
            for (id,start,end) in [("a",64800,72000),("b",68400,75600)] {
                try db.execute(sql:"INSERT INTO health_samples_raw VALUES(?, 'HKCategoryTypeIdentifierSleepAnalysis',?,?,1,0,'{}','com.apple.health','apple')",arguments:[id,start,end])
            }
        };try prepare(p);let s=try receiver();for (m,d) in try packets(p) { _=try s.ingest(manifest:m,payload:d) }
        let data=Data(try BridgeQuery(store:s).call("health_sleep",arguments:["date":"1970-01-02"]).utf8)
        let obj=try JSONSerialization.jsonObject(with:data) as! [String:Any];let r=obj["result"] as! [String:Any]
        XCTAssertEqual(r["totalSleepSeconds"] as? Double,10800);XCTAssertEqual(r["stageStatus"] as? String,"incomplete")
    }
    func testCivilSleepWindowDSTAndInvalidInputs() throws {
        for (date,zone,hours) in [("2026-03-08","America/New_York",23.0),("2026-11-01","America/New_York",25.0),("2026-09-19","Asia/Shanghai",24.0)] {
            XCTAssertEqual(try BridgeCalendarWindow.sleep(wakeDate:date,timeZone:zone).duration,hours*3600)
        }
        for date in ["2026-02-30","2026-9-19","not-a-date"] {
            XCTAssertThrowsError(try BridgeCalendarWindow.sleep(wakeDate:date,timeZone:"Asia/Shanghai"))
        }
        XCTAssertThrowsError(try BridgeCalendarWindow.sleep(wakeDate:"2026-09-19",timeZone:"invalid-zone"))
    }

    func testLargeSnapshotHasBoundedTemporaryMemory() throws {
        let pool = try source()
        let rowCount = ProcessInfo.processInfo.environment["HEALTHBRIDGE_STRESS_ROWS"].flatMap(Int.init) ?? 60000
        // SQL fixture generation avoids test-side Foundation allocation loops.
        try pool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<\(rowCount))
                INSERT INTO health_samples_raw
                SELECT printf('sample-%08d',n), 'HKQuantityTypeIdentifierHeartRate', n, n+1, 70, 0,
                  '{"categoryValue":1,"duration":60}', 'com.apple.health', 'apple' FROM seq
                """)
        }
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        // Model one uninterrupted export task: only the production code may drain
        // per-record Objective-C temporaries before the entire snapshot finishes.
        try autoreleasepool { try prepare(pool) }
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let growth = after.ru_maxrss - before.ru_maxrss
        print("HEALTHBRIDGE_SNAPSHOT_MEMORY growthBytes=\(growth) rows=\(rowCount)")
        XCTAssertLessThan(growth, 160 * 1024 * 1024, "Snapshot temporary memory must not grow with every row")
        XCTAssertEqual(try pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM bridge_outbox") },rowCount / 1000 + 1)
    }

}
