import XCTest

/// Boots the app with onboarding bypassed, taps every primary tab and a couple of
/// detail screens, asserts the navigation title or a known label appears. Failures
/// surface as test failures in the V2 acceptance run; on pass each screen yields
/// an XCTest attachment screenshot.
final class SmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_tabsAndCommonFlows_rendered() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        // Dashboard — title "摘要"
        XCTAssertTrue(
            app.staticTexts["摘要"].waitForExistence(timeout: 10),
            "Dashboard title 摘要 missing — onboarding bypass failed?"
        )
        attachScreenshot(named: "01-dashboard")

        // Tab 2: 饮食
        app.tabBars.buttons["饮食"].tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
        attachScreenshot(named: "02-diet")

        // Open meal-edit modal
        app.buttons["diet-add-meal"].tap()
        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))
        attachScreenshot(named: "02b-meal-edit")
        app.navigationBars["添加餐次"].buttons["取消"].tap()

        // Tab 3: 用药
        app.tabBars.buttons["用药"].tap()
        XCTAssertTrue(app.navigationBars["用药"].waitForExistence(timeout: 5))
        attachScreenshot(named: "03-meds")

        // Open med-plan edit
        app.navigationBars["用药"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["添加用药计划"].waitForExistence(timeout: 5))
        attachScreenshot(named: "03b-med-edit")
        app.navigationBars["添加用药计划"].buttons["取消"].tap()

        // Tab 4: 来源
        app.tabBars.buttons["来源"].tap()
        XCTAssertTrue(app.navigationBars["数据来源"].waitForExistence(timeout: 5))
        attachScreenshot(named: "04-sources")

        // Tab 5: 同步中心
        app.tabBars.buttons["同步中心"].tap()
        // Sync center hosts a NavigationStack-less header in some builds, so query loosely.
        XCTAssertTrue(
            app.staticTexts["同步中心"].waitForExistence(timeout: 5)
            || app.navigationBars["同步中心"].waitForExistence(timeout: 1)
        )
        attachScreenshot(named: "05-sync")

        // Settings via gear icon
        let gear = app.buttons.matching(identifier: "gearshape").firstMatch
        if gear.exists {
            gear.tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
            attachScreenshot(named: "06-settings")
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
