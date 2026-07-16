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

        XCTAssertTrue(
            anyDescendant(in: app, matching: "today-screen").waitForExistence(timeout: 20),
            "Today screen marker missing — onboarding bypass or tab mounting failed."
        )
        XCTAssertTrue(
            anyDescendant(in: app, matching: "today-summary-sleep").waitForExistence(timeout: 12),
            "Today loaded summary: today-summary-sleep missing."
        )
        XCTAssertTrue(
            anyDescendant(in: app, matching: "today-timeline").waitForExistence(timeout: 12),
            "Today loaded summary: today-timeline missing."
        )
        XCTAssertTrue(
            anyDescendant(in: app, matching: "today-source-coverage").waitForExistence(timeout: 12),
            "Today loaded summary: today-source-coverage missing."
        )
        XCTAssertFalse(
            anyDescendant(in: app, matching: "today-load-error").exists,
            "Today load error should not appear after loaded assertions."
        )
        if descendants(in: app, matching: "today-timeline-").count == 0 {
            XCTAssertTrue(app.staticTexts["今天还没有餐食或用药记录"].waitForExistence(timeout: 3))
        }
        attachScreenshot(named: "01-today")

        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["饮食"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["用药"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["趋势"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["仪表盘"].exists)
        XCTAssertFalse(app.tabBars.buttons["来源"].exists)
        XCTAssertFalse(app.tabBars.buttons["同步中心"].exists)

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

        // Tab 4: 趋势
        app.tabBars.buttons["趋势"].tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 8))
        attachScreenshot(named: "04-dashboard")

        // Trends -> card editor. Reset first so the interaction is deterministic,
        // then prove hide/show are reversible and leave the default layout behind.
        anyDescendant(in: app, matching: "dashboard-edit-cards").tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "dashboard-card-editor").waitForExistence(timeout: 5),
            "Dashboard card editor did not open."
        )
        revealBySwipingUp("dashboard-card-reset", in: app).tap()
        revealBySwipingDown("dashboard-card-hide-activity", in: app).tap()
        let showActivity = revealBySwipingUp("dashboard-card-show-activity", in: app)
        attachScreenshot(named: "04b-dashboard-card-editor-hidden-change")
        showActivity.tap()
        revealBySwipingUp("dashboard-card-reset", in: app).tap()
        _ = revealBySwipingDown("dashboard-card-hide-activity", in: app)
        attachScreenshot(named: "04c-dashboard-card-editor-default")
        anyDescendant(in: app, matching: "dashboard-card-done").tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 5))

        // Tab 5: 更多
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "more-screen").waitForExistence(timeout: 8),
            "More root marker missing."
        )
        attachScreenshot(named: "05-more")

        // More -> 数据来源
        anyDescendant(in: app, matching: "more-sources").tap()
        XCTAssertTrue(app.navigationBars["数据来源"].waitForExistence(timeout: 5))
        tapMoreBackButton(in: app, destinationTitle: "数据来源")
        XCTAssertTrue(anyDescendant(in: app, matching: "more-screen").waitForExistence(timeout: 8))

        // More -> 同步中心
        anyDescendant(in: app, matching: "more-sync-center").tap()
        XCTAssertTrue(app.navigationBars["同步中心"].waitForExistence(timeout: 5))
        tapMoreBackButton(in: app, destinationTitle: "同步中心")
        XCTAssertTrue(anyDescendant(in: app, matching: "more-screen").waitForExistence(timeout: 8))

        // More -> 设置
        anyDescendant(in: app, matching: "more-settings").tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        tapMoreBackButton(in: app, destinationTitle: "设置")
        XCTAssertTrue(anyDescendant(in: app, matching: "more-screen").waitForExistence(timeout: 8))
    }

    private func tapMoreBackButton(in app: XCUIApplication, destinationTitle: String) {
        let backButton = app.navigationBars[destinationTitle].buttons["更多"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "\(destinationTitle) is missing its More back button.")
        backButton.tap()
    }

    private func anyDescendant(in app: XCUIApplication, matching identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func descendants(in app: XCUIApplication, matching identifierPrefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
    }

    private func revealBySwipingUp(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = anyDescendant(in: app, matching: identifier)
        for _ in 0..<8 {
            if element.exists && element.isHittable { return element }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reveal \(identifier) by scrolling down.")
        return element
    }

    private func revealBySwipingDown(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = anyDescendant(in: app, matching: identifier)
        for _ in 0..<8 {
            if element.exists && element.isHittable { return element }
            app.swipeDown()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reveal \(identifier) by scrolling up.")
        return element
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
