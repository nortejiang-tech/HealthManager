import XCTest

/// Dedicated QA simulator only. No account, API Key, or real health samples.
final class VibrantRenderingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCardsMainPagesAndGarminEntry() {
        let app = XCUIApplication()
        let large = ProcessInfo.processInfo.environment["VIBRANT_QA_LARGE"] == "1"
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING", "-hm.display.mode.v1", "cards"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["趋势"].waitForExistence(timeout: 15))
        XCTAssertTrue(item(app, "dashboard-vibrant-header").waitForExistence(timeout: 10))
        capture("cards-trends")

        app.tabBars.buttons["饮食"].tap()
        XCTAssertTrue(item(app, "diet-calorie-total").waitForExistence(timeout: 15))
        XCTAssertTrue(item(app, "diet-add-meal").exists)
        capture("cards-diet")
        app.tabBars.buttons["营养表"].tap()
        XCTAssertTrue(item(app, "nutrition-vibrant-header").waitForExistence(timeout: 10))
        capture("cards-nutrition")

        app.tabBars.buttons["锻炼"].tap()
        XCTAssertTrue(item(app, "garmin-card-bodyBattery").waitForExistence(timeout: 15))
        capture("cards-garmin")
        reveal(app, "garmin-readiness-unavailable").tap()
        XCTAssertTrue(reveal(app, "garmin-readiness-connect").exists)
        capture("cards-readiness-unavailable")
        reveal(app, "training-volume-card").tap()
        XCTAssertTrue(app.navigationBars["已记录跑步时长"].waitForExistence(timeout: 10))
        capture("cards-training-detail")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(app, "training-open-trends").tap()
        XCTAssertTrue(item(app, "training-trend-metric").waitForExistence(timeout: 10))
        capture("cards-training-trends")

        app.tabBars.buttons["更多"].tap()
        capture("cards-more")
        reveal(app, "more-settings").tap()
        XCTAssertTrue(item(app, "settings-appearance").waitForExistence(timeout: 5))
        capture("cards-settings")
        reveal(app, "settings-garmin").tap()
        XCTAssertTrue(app.navigationBars["佳明健康监测"].waitForExistence(timeout: 5))
        capture("cards-garmin-connection")
        app.terminate()
    }

    func testDisplayChoicePersistsAndClassicCanReturnToCards() {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()
        openAppearance(app)
        reveal(app, "display-mode-classic").tap()
        XCTAssertTrue(app.navigationBars["显示模式"].exists, "Changing appearance should keep the settings page open")
        XCTAssertTrue(item(app, "display-mode-classic").label.contains("当前已选择"))
        capture("classic-selection")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 15))
        XCTAssertFalse(item(app, "dashboard-vibrant-header").exists)
        openAppearance(app)
        XCTAssertTrue(item(app, "display-mode-classic").label.contains("当前已选择"))
        reveal(app, "display-mode-cards").tap()
        XCTAssertTrue(app.navigationBars["显示模式"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(item(app, "dashboard-vibrant-header").waitForExistence(timeout: 15))
        app.terminate()
    }

    private func openAppearance(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 15))
        app.tabBars.buttons["更多"].tap()
        reveal(app, "more-settings").tap()
        reveal(app, "settings-appearance").tap()
        XCTAssertTrue(app.navigationBars["显示模式"].waitForExistence(timeout: 5))
    }
    private func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = item(app, id)
        for _ in 0..<18 {
            if target.exists && target.isHittable { return target }
            app.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Cannot reach \(id)")
        return target
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
