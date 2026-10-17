import XCTest

/// Real rendering, navigation and readable controls using only the dedicated QA simulator.
final class TrainingRenderingUITests: XCTestCase {
    func test_trainingEvidenceAndTrendsRemainReachableAcrossDisplayModes() throws {
        continueAfterFailure = false
        let appearance = ProcessInfo.processInfo.environment["TRAINING_QA_APPEARANCE"] ?? "light"
        let modes: [(String, [String])] = appearance == "dark" ? [("dark", [])] : [
            ("light", []), ("large", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, arguments) in modes {
            let app = XCUIApplication()
            app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"] + arguments
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout: 15))
            app.tabBars.buttons["锻炼"].tap()
            XCTAssertTrue(element(app, "training-readiness-score").waitForExistence(timeout: 20))
            XCTAssertFalse(app.staticTexts["训练计划"].exists)
            screenshot("v2-\(name)-overview")
            app.buttons["training-method"].tap()
            XCTAssertTrue(app.navigationBars["计算依据与可信度"].waitForExistence(timeout: 5))
            screenshot("v2-\(name)-method")
            app.buttons["training-method-done"].tap()

            app.segmentedControls["training-sections"].buttons["趋势"].tap()
            XCTAssertTrue(element(app, "training-trend-metric").waitForExistence(timeout: 5))
            app.segmentedControls["training-window"].buttons["7天"].tap()
            app.segmentedControls["training-window"].buttons["8周"].tap()
            screenshot("v2-\(name)-readiness-history")
            app.segmentedControls.buttons["能力"].tap()
            screenshot("v2-\(name)-capability-trend")

            app.segmentedControls["training-sections"].buttons["全部参数"].tap()
            let search = app.textFields["training-parameter-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText("VO\n")
            let vo2 = reveal(app, "training-parameter-vo2")
            vo2.tap()
            XCTAssertTrue(element(app, "training-metric-vo2").waitForExistence(timeout: 15))
            screenshot("v2-\(name)-parameter-detail")
            reveal(app, "training-raw-records").tap()
            XCTAssertTrue(app.navigationBars["相关原始记录"].waitForExistence(timeout: 5))
            screenshot("v2-\(name)-raw-records")
            app.navigationBars.buttons.firstMatch.tap()
            app.navigationBars.buttons.firstMatch.tap()
            reveal(app, "training-workouts", down: true).tap()
            XCTAssertTrue(app.navigationBars["运动"].waitForExistence(timeout: 5))
            app.buttons["补录活动"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["补录活动"].waitForExistence(timeout: 5))
            screenshot("v2-\(name)-manual-entry")
            app.buttons["取消"].tap()
            app.tabBars.buttons["更多"].tap()
            XCTAssertFalse(element(app, "more-workouts").exists)
            app.terminate()
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ app: XCUIApplication, _ id: String, down: Bool = false) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<10 {
            if target.exists && target.isHittable { return target }
            if down { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(target.exists && target.isHittable, "Cannot reach \(id)")
        return target
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
