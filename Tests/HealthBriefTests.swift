import XCTest
import GRDB
@testable import HealthManager

final class HealthBriefTests: XCTestCase {
    func fact(_ id:String,_ value:Double?,note:String="") -> BriefFact {
        BriefFact(id:id,title:id,value:value,unit:"",date:"2026-10-24",source:"Garmin Connect",note:note)
    }
    func snapshot(sleep:Double?=82,hrv:Double?=47,baseline:String="BALANCED",battery:Double?=68) -> HealthBriefSnapshot {
        HealthBriefRules.make(id:"test",day:"2026-10-24",phase:"morning",facts:[fact("sleep",sleep),fact("hrv",hrv),fact("hrvBaseline",baseline == "NONE" ? nil : 40,note:baseline),fact("battery",battery)],training:[])
    }
    func narrative(_ s:HealthBriefSnapshot) -> BriefNarrative {
        BriefNarrative(snapshot_id:s.id,state:s.defaultState,headline:"今日健康速报",summary:s.localSummary,factors:[BriefFactor(fact_ids:["sleep"],direction:"neutral",text:"睡眠记录已形成")],focus:"observe",limitations:[])
    }
    func testMissingSignalsCannotBecomeRecoveryConclusion() {
        let s=snapshot(sleep:nil);XCTAssertEqual(s.allowedStates,[.limited]);var n=narrative(s);n.state = .steady
        XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))
    }
    func testBaselineIsRequiredRegardlessOfPopulationHRVValue() {
        for hrv in [20.0,47,120] {let s=snapshot(hrv:hrv,baseline:"NONE");XCTAssertEqual(s.defaultState,.baseline);XCTAssertEqual(s.allowedStates,[.baseline])}
    }
    func testLimitedAndBaselineTextCannotOverruleLocalConclusion() {
        let s=snapshot(baseline:"NONE");var n=narrative(s)
        n.headline=s.defaultState.title
        XCTAssertTrue(HealthBriefRules.validate(narrative:n,for:s))
        n.summary="你的恢复非常好";XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))
    }
    func testCorrelatedBatteryOnlyDowngradesAndPoorSignalsConstrainState() {
        XCTAssertEqual(snapshot().defaultState,.steady)
        XCTAssertEqual(snapshot(battery:10).defaultState,.mixed)
        XCTAssertEqual(snapshot(sleep:55).defaultState,.caution)
        XCTAssertFalse(snapshot(baseline:"LOW").allowedStates.contains(.steady))
    }
    func testNarrativeValidationRejectsStaleUnknownInventedNumbersAndMedicalAdvice() {
        let s=snapshot();let clean=narrative(s);XCTAssertTrue(HealthBriefRules.validate(narrative:clean,for:s))
        var n=clean;n.snapshot_id="yesterday";XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))
        n=clean;n.factors[0].fact_ids=["invented"];XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))
        for text in ["HRV为999", "可以停药", "保证恢复", "已确诊"] {n=clean;n.summary=text;XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))}
        n=clean;n.state = .caution;XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s))
    }
    func testLoaderUsesWakeDateAndNeverSubstitutesAppleSDNNOrYesterday() async throws {
        let db=DatabaseManager.makeInMemoryForTesting()
        let now=WeightProjection.day("2026-10-24")!.addingTimeInterval(10*3600)
        try db.write { d in
            var sleep=GarminMetricPayload();sleep.values["primary"]=68
            var hrv=GarminMetricPayload();hrv.values["primary"]=47
            try GarminStore.save(db:d,metric:.sleep,date:"2026-10-24",payload:sleep,attemptedAt:now)
            try GarminStore.save(db:d,metric:.hrv,date:"2026-10-23",payload:hrv,attemptedAt:now)
            var battery=GarminMetricPayload();battery.values["primary"]=20;battery.observedAt=now.addingTimeInterval(-7*3600).timeIntervalSince1970
            try GarminStore.save(db:d,metric:.bodyBattery,date:"2026-10-24",payload:battery,attemptedAt:now)
        }
        let s=try await HealthBriefLoader.load(database:db,training:nil,now:now)
        XCTAssertEqual(s.defaultState,.limited);XCTAssertNil(s.facts.first{$0.id=="hrv"}?.value)
        XCTAssertNil(s.facts.first{$0.id=="battery"}?.value)
        XCTAssertEqual(s.facts.first{$0.id=="sleep"}?.value,68)
        XCTAssertTrue(s.training.allSatisfy{$0.load == nil && $0.incomplete})
    }
    func testHashIgnoresFetchTimeButChangesForActualValuesAndPhase() async throws {
        let db=DatabaseManager.makeInMemoryForTesting();let now=WeightProjection.day("2026-10-24")!.addingTimeInterval(10*3600)
        var sleep=GarminMetricPayload();sleep.values["primary"]=68
        try db.write { try GarminStore.save(db:$0,metric:.sleep,date:"2026-10-24",payload:sleep,attemptedAt:now) }
        let a=try await HealthBriefLoader.load(database:db,training:nil,now:now)
        try db.write { try GarminStore.save(db:$0,metric:.sleep,date:"2026-10-24",payload:sleep,attemptedAt:now.addingTimeInterval(60)) }
        let b=try await HealthBriefLoader.load(database:db,training:nil,now:now.addingTimeInterval(60))
        XCTAssertEqual(a.id,b.id)
        sleep.values["primary"]=70
        try db.write { try GarminStore.save(db:$0,metric:.sleep,date:"2026-10-24",payload:sleep,attemptedAt:now) }
        let c=try await HealthBriefLoader.load(database:db,training:nil,now:now)
        XCTAssertNotEqual(a.id,c.id)
        let evening=try await HealthBriefLoader.load(database:db,training:nil,now:now.addingTimeInterval(10*3600))
        XCTAssertNotEqual(c.id,evening.id)
    }
    func testBriefClientSendsOnlySnapshotUsesBoundedRequestAndParsesUsage() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[BriefProtocol.self]
        let s=snapshot();let n=narrative(s)
        let content=String(decoding:try JSONEncoder().encode(n),as:UTF8.self)
        BriefProtocol.data=try JSONSerialization.data(withJSONObject:["choices":[["message":["content":content]]],"usage":["prompt_tokens":321,"completion_tokens":85]])
        BriefProtocol.status=200
        let client=LLMClient(baseURL:"https://brief.invalid/v1",model:"synthetic-test",apiKey:"",session:URLSession(configuration:config))
        let response=try await client.completeHealthBrief(snapshot:s)
        XCTAssertEqual(response.inputTokens,321);XCTAssertEqual(response.outputTokens,85)
        XCTAssertEqual(try JSONDecoder().decode(BriefNarrative.self,from:response.content),n)
        XCTAssertEqual(BriefProtocol.timeout,18);XCTAssertEqual(BriefProtocol.path,"/v1/chat/completions")
        BriefProtocol.status=503
        do { _=try await client.completeHealthBrief(snapshot:s);XCTFail("server errors must use local fallback") } catch {}
    }
    func testMiniMaxBriefRequestReservesThinkingBudgetAndUsesLowEffort() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[BriefProtocol.self]
        let s=snapshot();let n=narrative(s)
        BriefProtocol.status=200
        BriefProtocol.data=try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":String(decoding:try JSONEncoder().encode(n),as:UTF8.self)]]]])
        let client=LLMClient(baseURL:"https://api.minimaxi.com/v1",model:"MiniMax-M3.1-Flash",apiKey:"",session:URLSession(configuration:config))
        _=try await client.completeHealthBrief(snapshot:s)
        XCTAssertEqual(BriefProtocol.body["reasoning_effort"] as? String,"low")
        XCTAssertEqual(BriefProtocol.body["max_completion_tokens"] as? Int,4096)
        XCTAssertEqual(BriefProtocol.body["reasoning_split"] as? Bool,true)
        XCTAssertNil(BriefProtocol.body["thinking"],"M3.1 thinking cannot be disabled")
    }
    func testMigrationArchivesOriginalBeforeInvalidatingLLM() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite").path
        let pool=try DatabasePool(path:path)
        try Migrations.makeMigrator().migrate(pool,upTo:"v17_workout_event_projection")
        try pool.write { try $0.execute(sql:"INSERT INTO daily_summaries(date,summary_text,generated_at,llm_text) VALUES('2026-10-23','original report',1,'original LLM')") }
        try Migrations.run(on:pool)
        try pool.read { db in
            let archive=try XCTUnwrap(String.fetchOne(db,sql:"SELECT original_json FROM summary_contract_archive"))
            XCTAssertTrue(archive.contains("original report"));XCTAssertTrue(archive.contains("original LLM"))
            XCTAssertNil(try String.fetchOne(db,sql:"SELECT llm_text FROM daily_summaries"))
        }
    }
}
private final class BriefProtocol: URLProtocol {
    static var body:[String:Any]=[:]
    static var data=Data();static var status=200;static var timeout:TimeInterval=0;static var path=""
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if let data=request.httpBody { Self.body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
        else if let stream=request.httpBodyStream {
            stream.open();defer {stream.close()};var data=Data();var bytes=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable {let n=stream.read(&bytes,maxLength:bytes.count);if n<=0 {break};data.append(contentsOf:bytes.prefix(n))}
            Self.body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        }
        Self.timeout=request.timeoutInterval;Self.path=request.url!.path
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
