import XCTest
@testable import HealthManager

final class MetricPresentationTests: XCTestCase {

    private func makePoint(_ dayOffset: Int, _ value: Double?) -> MetricPoint {
        MetricPoint(
            date: Date(timeIntervalSince1970: TimeInterval(dayOffset * 86_400)),
            value: value
        )
    }

    // MARK: - 空值 / 缺值

    func test_yDomain_empty_returnsUnitRange() {
        XCTAssertEqual(MetricPresentation.yDomain(points: [], chartStyle: .line), 0...1)
    }

    func test_yDomain_allNil_returnsUnitRange() {
        let points = [makePoint(0, nil), makePoint(1, nil)]
        XCTAssertEqual(MetricPresentation.yDomain(points: points, chartStyle: .line), 0...1)
    }

    func test_yDomain_ignoresNilValues() {
        let points = [makePoint(0, nil), makePoint(1, 10), makePoint(2, 20)]
        let domain = MetricPresentation.yDomain(points: points, chartStyle: .line)
        XCTAssertEqual(domain, 8.5...21.5) // span 10, ±15%
    }

    // MARK: - 单一取值

    func test_yDomain_singleValue_padsAroundIt() {
        let domain = MetricPresentation.yDomain(points: [makePoint(0, 100)], chartStyle: .line)
        XCTAssertEqual(domain, 95...105) // ±5%
    }

    func test_yDomain_singleSmallValue_usesAbsoluteFloor() {
        let domain = MetricPresentation.yDomain(points: [makePoint(0, 2)], chartStyle: .line)
        XCTAssertEqual(domain, 1.5...2.5) // max(2*0.05, 0.5) = 0.5
    }

    // MARK: - 柱状图 0 基线

    func test_yDomain_bar_includesZeroBaseline() {
        let domain = MetricPresentation.yDomain(
            points: [makePoint(0, 50), makePoint(1, 60)],
            chartStyle: .bar
        )
        XCTAssertEqual(domain.lowerBound, 0)
        XCTAssertGreaterThan(domain.upperBound, 60)
    }

    func test_yDomain_bar_withNegativeValues_stillIncludesZero() {
        let domain = MetricPresentation.yDomain(
            points: [makePoint(0, -30), makePoint(1, 10)],
            chartStyle: .bar
        )
        XCTAssertLessThanOrEqual(domain.lowerBound, -30)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 10)
    }

    // MARK: - 自适应（本轮需求的核心回归）

    func test_yDomain_adaptsToVisibleWindow_notFullRange() {
        // 全年 100 天取值 5…104；若纵轴锁定全期间，窗口内 5…11 的变化会被压平。
        let fullRange = (0..<100).map { makePoint($0, 5 + Double($0)) }
        let visibleWindow = Array(fullRange[0..<7]) // 5…11

        let fullDomain = MetricPresentation.yDomain(points: fullRange, chartStyle: .line)
        let windowDomain = MetricPresentation.yDomain(points: visibleWindow, chartStyle: .line)

        XCTAssertEqual(fullDomain.lowerBound, 5 - 99 * 0.15, accuracy: 0.001)
        XCTAssertEqual(fullDomain.upperBound, 104 + 99 * 0.15, accuracy: 0.001)
        XCTAssertLessThan(windowDomain.upperBound - windowDomain.lowerBound, 10)
        XCTAssertNotEqual(fullDomain, windowDomain)
    }
}
