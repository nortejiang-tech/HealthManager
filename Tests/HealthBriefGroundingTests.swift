import XCTest
@testable import HealthManager

final class HealthBriefGroundingTests: XCTestCase {
    func snapshot()->HealthBriefSnapshot {
        HealthBriefRules.make(id:"current",day:"2026-10-24",phase:"morning",facts:[
            BriefFact(id:"sleep",title:"睡眠评分",value:68,unit:"",date:"2026-10-24",source:"Garmin",note:""),
            BriefFact(id:"hrv",title:"夜间HRV",value:47,unit:"ms",date:"2026-10-24",source:"Garmin",note:""),
            BriefFact(id:"battery",title:"电量",value:nil,unit:"",date:"2026-10-24",source:"Garmin",note:"")],training:[])
    }
    func proposal()->BriefNarrative {
        BriefNarrative(snapshot_id:"current",state:.baseline,headline:"正在积累个人基线",summary:"已有睡眠和心率变异性记录，基线尚在积累。",factors:[BriefFactor(fact_ids:["sleep"],direction:"neutral",text:"睡眠评分68分，继续观察。"),BriefFactor(fact_ids:["battery"],direction:"positive",text:"电量充足")],focus:"observe",limitations:[])
    }
    func testProviderWordingDifferencesCompileWithoutChangingBaselineConclusion() throws {
        let s=snapshot(), n=proposal()
        XCTAssertFalse(HealthBriefRules.validate(narrative:n,for:s),"Reproduces v25 local evidence rejection on a valid provider envelope")
        let p=try XCTUnwrap(HealthBriefGrounding.prepare(n,for:s))
        XCTAssertEqual(p.narrative.state,.baseline);XCTAssertEqual(p.narrative.summary,s.localSummary)
        XCTAssertTrue(HealthBriefRules.validate(narrative:p.narrative,for:s))
        XCTAssertEqual(p.narrative.factors.count,1);XCTAssertFalse(p.narrative.factors[0].text.contains("68"))
        XCTAssertTrue(p.repairs.contains("baseline_summary_wording"))
    }
    func testWrongSnapshotStillRejectedAndUnsupportedHealthConclusionCannotSurvive() throws {
        let s=snapshot();var n=proposal();n.snapshot_id="old"
        XCTAssertNil(HealthBriefGrounding.prepare(n,for:s))
        n.snapshot_id=s.id;n.state = .steady;n.summary="保证恢复很好";n.focus="routine"
        let p=try XCTUnwrap(HealthBriefGrounding.prepare(n,for:s))
        XCTAssertEqual(p.narrative.state,.baseline);XCTAssertEqual(p.narrative.focus,"observe")
        XCTAssertEqual(p.narrative.summary,s.localSummary)
    }
    func testUnknownFactOrMissingValuesCannotAcquireEvidence() throws {
        var n=proposal();n.factors=[BriefFactor(fact_ids:["invented"],direction:"positive",text:"数据很好")]
        let p=try XCTUnwrap(HealthBriefGrounding.prepare(n,for:snapshot()))
        XCTAssertTrue(p.narrative.factors.isEmpty)
    }
}
