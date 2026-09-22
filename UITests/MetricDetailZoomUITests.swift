import XCTest

/// 年视图双指捏合缩放回归。前置条件：模拟器 App 容器内已种入
/// `body_metrics_daily` 一年数据（ wiping 模拟器后需重新种数）。
final class MetricDetailZoomUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 「重置缩放」按钮只在 xZoom > 1.01 时渲染，因此它出现即证明
    /// MagnifyGesture 管线真实触发（此前 .gesture 被 Charts 内部滚动
    /// 识别器抢占、onChanged 从未执行，正是用户反馈的失效根因）。
    func testYearViewPinchZoomShowsResetControlAndRestores() {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        let weightCard = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "体重 / 体成分"))
            .firstMatch
        XCTAssertTrue(weightCard.waitForExistence(timeout: 15), "趋势页未出现体重卡片")
        weightCard.tap()

        XCTAssertTrue(app.navigationBars["体重"].waitForExistence(timeout: 8))
        app.buttons["年"].tap()

        let chart = app.descendants(matching: .any)
            .matching(identifier: "metric-detail-chart")
            .firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 8), "年视图图表未渲染（模拟器需已种 body_metrics_daily 数据）")

        let fullShot = XCTAttachment(screenshot: app.screenshot())
        fullShot.name = "year-full-domain"
        fullShot.lifetime = .keepAlways
        add(fullShot)

        chart.pinch(withScale: 3.0, velocity: 1000)

        let resetButton = app.buttons["chart-reset-zoom"].firstMatch
        XCTAssertTrue(resetButton.waitForExistence(timeout: 3), "捏合后应出现重置缩放按钮（MagnifyGesture 未触发）")

        let pinchedShot = XCTAttachment(screenshot: app.screenshot())
        pinchedShot.name = "year-pinched-zoom"
        pinchedShot.lifetime = .keepAlways
        add(pinchedShot)

        resetButton.tap()
        XCTAssertFalse(resetButton.waitForExistence(timeout: 2), "点按重置后按钮应消失")
    }
}
