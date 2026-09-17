import XCTest

/// v0.6 信息架构冒烟：冷启动落趋势页（今日一级页已移除），五个 Tab 依次可达，
/// 营养表展示官方目录条目；各主页面给出可访问性标记与截图。
final class SmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_tabsAndCommonFlows_rendered() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        // 冷启动第一栏 = 趋势（A01）；不再有「今日」一级页。
        XCTAssertTrue(
            anyDescendant(in: app, matching: "dashboard-screen").waitForExistence(timeout: 20),
            "Dashboard screen marker missing — onboarding bypass or tab mounting failed."
        )
        XCTAssertTrue(app.tabBars.buttons["趋势"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["饮食"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["用药"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["营养表"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["更多"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["今日"].exists, "今日一级页应已移除")
        XCTAssertFalse(app.tabBars.buttons["仪表盘"].exists)
        XCTAssertFalse(app.tabBars.buttons["来源"].exists)
        XCTAssertFalse(app.tabBars.buttons["同步中心"].exists)
        attachScreenshot(named: "01-trends-home")

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

        // Tab 4: 营养表（参考食材段展示官方目录）
        app.tabBars.buttons["营养表"].tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "nutrition-screen").waitForExistence(timeout: 8),
            "Nutrition screen marker missing."
        )
        XCTAssertTrue(
            anyDescendant(in: app, matching: "nutrition-search").waitForExistence(timeout: 8),
            "Nutrition search field missing."
        )
        XCTAssertTrue(
            anyDescendant(in: app, matching: "nutrition-entry-mext-01088").waitForExistence(timeout: 8),
            "Catalog entry (熟白米饭) missing from reference list."
        )
        attachScreenshot(named: "04-nutrition")

        // 营养表 → 详情 → 关闭（不落任何数据）。
        anyDescendant(in: app, matching: "nutrition-entry-mext-01088").tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "nutrition-add-to-meal").waitForExistence(timeout: 5),
            "Nutrition detail (加入饮食) missing."
        )
        attachScreenshot(named: "04b-nutrition-detail")
        anyDescendant(in: app, matching: "nutrition-detail-close").tap()

        // 我的常吃段可达（空数据时展示空状态而非崩溃）。
        app.tabBars.buttons["营养表"].tap()
        let frequentSegment = app.segmentedControls.buttons["我的常吃"]
        if frequentSegment.waitForExistence(timeout: 3) {
            frequentSegment.tap()
            attachScreenshot(named: "04c-nutrition-frequent")
        }

        // Tab 5: 趋势页卡片编辑仍可用。
        app.tabBars.buttons["趋势"].tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 8))
        anyDescendant(in: app, matching: "dashboard-edit-cards").tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "dashboard-card-editor").waitForExistence(timeout: 5),
            "Dashboard card editor did not open."
        )
        revealBySwipingUp("dashboard-card-reset", in: app).tap()
        revealBySwipingDown("dashboard-card-hide-activity", in: app).tap()
        let showActivity = revealBySwipingUp("dashboard-card-show-activity", in: app)
        attachScreenshot(named: "05-dashboard-card-editor-hidden-change")
        showActivity.tap()
        revealBySwipingUp("dashboard-card-reset", in: app).tap()
        _ = revealBySwipingDown("dashboard-card-hide-activity", in: app)
        attachScreenshot(named: "05b-dashboard-card-editor-default")
        anyDescendant(in: app, matching: "dashboard-card-done").tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 5))

        // Tab 6: 更多
        app.tabBars.buttons["更多"].tap()
        XCTAssertTrue(
            anyDescendant(in: app, matching: "more-screen").waitForExistence(timeout: 8),
            "More root marker missing."
        )
        attachScreenshot(named: "06-more")

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
