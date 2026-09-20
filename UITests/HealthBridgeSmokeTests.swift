import XCTest

final class HealthBridgeSmokeTests: XCTestCase {
    func testSettingsRouteAndDisabledDefault() {
        let app=XCUIApplication()
        app.launchArguments=["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout:20))
        app.tabBars.buttons["更多"].tap()
        let settings=app.descendants(matching:.any).matching(identifier:"more-settings").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        let bridge=app.buttons["健康管家同步（iCloud）"]
        for _ in 0..<4 { if bridge.isHittable { break };app.swipeUp() }
        XCTAssertTrue(bridge.exists);bridge.tap()
        XCTAssertTrue(app.navigationBars["健康管家同步"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["bridge.syncStatus"].exists)
        XCTAssertFalse(app.buttons["立即同步 / 检查 Mac 回执"].isEnabled)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="healthbridge-settings-disabled";screenshot.lifetime = .keepAlways;add(screenshot)
    }
}
