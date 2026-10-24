import XCTest
@testable import BridgeCore

final class WeightPolicyTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ day: Int = 23, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))! }
    func obs(_ id: String, _ time: Date, _ value: Double, _ source: String = "mijia") -> WeightObservation {
        WeightObservation(id: id, date: time, kilograms: value, source: source, origin: source == "mijia" ? "xiaomiMijia" : source)
    }
    func project(_ rows: [WeightObservation], day: Int = 23) -> WeightDayProjection { WeightAggregationPolicy.project(observations: rows, day: date(day, 12), calendar: cal) }
    func testSyntheticExampleAndRepeatedMorningInvariance() throws {
        for count in [1,3,5] {
            let rows = (0..<count).map { obs("am\($0)",date(23,8,$0),70.3) } + [obs("pm",date(23,20),72.2),obs("manual",date(23,14),76,"Garmin")]
            let p = project(rows)
            XCTAssertEqual(try XCTUnwrap(p.mean),71.25,accuracy:0.00001)
            XCTAssertEqual(p.eventCount,2); XCTAssertEqual(p.excludedGarminCount,1)
            XCTAssertEqual(p.strata.map(\.slot),[1,3]); XCTAssertEqual(WeightAggregationPolicy.displayKilograms(p.mean!),"71.3")
        }
    }
    func testRawEligibilityMatchesChineseScaleNamesAndAlwaysExcludesGarmin() {
        XCTAssertNil(WeightAggregationPolicy.exclusionReason(source:"米家",origin:"unknown"))
        XCTAssertEqual(WeightAggregationPolicy.exclusionReason(source:"Garmin|米家",origin:"xiaomiMijia"),"garmin_manual_weight")
        XCTAssertEqual(WeightAggregationPolicy.exclusionReason(source:"Apple Health",origin:"apple"),"unconfirmed_scale_source")
    }
    func testGarminNeverFallsBackAndInvalidOtherSourcesStayUnknown() {
        let rows = [obs("g",date(23,8),76,"com.GARMIN.connect"),obs("a",date(23,8),78,"apple"),obs("nan",date(23,8),.nan),obs("inf",date(23,8),.infinity),obs("n",date(23,8),-2)]
        let p = project(rows); XCTAssertNil(p.mean); XCTAssertEqual(p.excludedGarminCount,1); XCTAssertEqual(p.excludedOtherCount,1)
    }
    func testAnchoredEventCannotChainAndSlotMedianRejectsOutlier() throws {
        let rows = [obs("a",date(23,8),70),obs("b",date(23,8,29),72),obs("c",date(23,8,58),80),obs("d",date(23,10),200)]
        let p = project(rows); XCTAssertEqual(p.eventCount,3); XCTAssertEqual(try XCTUnwrap(p.mean),80)
    }
    func testMidnightEventAssignedExactlyOnce() throws {
        let rows = [obs("a",date(23,23,50),76),obs("b",date(24,0,10),78)]
        XCTAssertNil(project(rows).mean)
        let p = project(rows,day:24); XCTAssertEqual(p.mean,77); XCTAssertEqual(p.eventCount,1); XCTAssertEqual(p.acceptedCount,1)
    }
    func testStableIdentityDedupAndPermutationInvariance() {
        let rows = [obs("same",date(23,8),78),obs("same",date(23,8),76),obs("z",date(23,20),80)]
        XCTAssertEqual(project(rows),project(rows.reversed())); XCTAssertEqual(project(rows).acceptedCount,2)
    }
    func testDSTUsesLocalClockSlotsAndFiniteLargeNumbers() throws {
        var c = Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"America/New_York")!
        let day = c.date(from:DateComponents(year:2026,month:11,day:1,hour:23))!
        let p=WeightAggregationPolicy.project(observations:[obs("x",day,Double.greatestFiniteMagnitude),obs("y",day.addingTimeInterval(60),Double.greatestFiniteMagnitude)],day:day,calendar:c)
        XCTAssertEqual(p.strata.first?.slot,3);XCTAssertTrue(try XCTUnwrap(p.mean).isFinite)
    }
}
