import XCTest

final class HealthBriefRenderingUITests: XCTestCase {
    override func setUp() { continueAfterFailure=false }
    func testBriefFactsQualityAlertsDetailsAndAIControls() {
        let app=launch()
        XCTAssertTrue(item(app,"health-brief-title").waitForExistence(timeout:20))
        XCTAssertTrue(item(app,"health-brief-hrv").exists)
        XCTAssertTrue(item(app,"health-brief-sleep").exists)
        XCTAssertTrue(item(app,"health-brief-battery").exists)
        capture("brief-default")
        let ai=item(app,"health-brief-analyze")
        if ai.isHittable { ai.tap() }
        XCTAssertTrue(app.staticTexts["请先在设置中配置并启用 AI 文本通道"].waitForExistence(timeout:5))
        reveal(app, label:"依据与来源").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","Garmin Connect")).firstMatch.waitForExistence(timeout:5))
        capture("brief-evidence")
        XCTAssertTrue(item(app,"health-brief-analyze").exists)
        app.terminate()
    }
    func testLargeTextAndClassicKeepHealthBriefReadable() {
        let app=launch(extra:["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"],mode:"classic")
        XCTAssertTrue(item(app,"health-brief-title").waitForExistence(timeout:20))
        XCTAssertTrue(item(app,"dashboard-health-brief-classic").exists)
        capture("brief-large-classic-top")
        app.swipeUp();capture("brief-large-classic-facts")
        XCTAssertTrue(item(app,"health-brief-battery").exists)
        app.terminate()
    }
    func testQualityAndAlertEntrancesRemainReachable() {
        let app=launch()
        XCTAssertTrue(item(app,"health-brief-title").waitForExistence(timeout:20))
        app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","数据质量：")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["数据质量"].waitForExistence(timeout:5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons.matching(NSPredicate(format:"label CONTAINS %@","待检查")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["告警"].waitForExistence(timeout:5))
        app.terminate()
    }
    func testManualGenerationPresentsReopensAndRegeneratesSheet() {
        let app = launch(extra: ["-HM_UI_TEST_BRIEF_RESPONSE"])
        XCTAssertTrue(item(app, "health-brief-title").waitForExistence(timeout: 20))
        reveal(app, label: "AI解读").tap()
        XCTAssertTrue(app.navigationBars["AI解读"].waitForExistence(timeout: 10))
        XCTAssertTrue(item(app, "health-brief-sheet-summary").exists)
        capture("brief-ai-sheet")
        item(app, "health-brief-sheet-close").tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 5))
        let viewButton = reveal(app, label: "查看AI解读")
        XCTAssertTrue(viewButton.exists)
        viewButton.tap()
        XCTAssertTrue(app.navigationBars["AI解读"].waitForExistence(timeout: 5))
        reveal(app, label: "重新解读").tap()
        XCTAssertTrue(app.navigationBars["AI解读"].waitForExistence(timeout: 10))
        XCTAssertTrue(item(app, "health-brief-sheet-summary").exists)
        item(app, "health-brief-sheet-close").tap()
        app.terminate()
    }
    func testFailedGenerationDoesNotPresentSuccessSheet() {
        let app = launch(extra: ["-HM_UI_TEST_BRIEF_RESPONSE", "-HM_UI_TEST_BRIEF_FAILURE"])
        XCTAssertTrue(item(app, "health-brief-title").waitForExistence(timeout: 20))
        reveal(app, label: "AI解读").tap()
        XCTAssertTrue(app.staticTexts["AI 响应超时，可重试 · 本地汇总仍有效"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["AI解读"].exists)
        app.terminate()
    }
    func testInterpretationSheetAtAccessibilityLargeText() {
        let app = launch(extra: ["-HM_UI_TEST_BRIEF_RESPONSE", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], mode: "classic")
        XCTAssertTrue(item(app, "health-brief-title").waitForExistence(timeout: 20))
        reveal(app, label: "AI解读").tap()
        XCTAssertTrue(app.navigationBars["AI解读"].waitForExistence(timeout: 10))
        capture("brief-ai-sheet-large-top")
        XCTAssertTrue(reveal(app, label: "重新解读").isHittable)
        capture("brief-ai-sheet-large-bottom")
        item(app, "health-brief-sheet-close").tap()
        XCTAssertTrue(app.navigationBars["趋势"].waitForExistence(timeout: 5))
        app.terminate()
    }
    private func launch(extra:[String]=[],mode:String="cards")->XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["-HM_DEBUG_BYPASS_ONBOARDING","-hm.display.mode.v1",mode,"-llm.enabled","NO"]+extra
        app.launch();XCTAssertTrue(app.tabBars.buttons["趋势"].waitForExistence(timeout:15));app.tabBars.buttons["趋势"].tap();return app
    }
    private func item(_ a:XCUIApplication,_ id:String)->XCUIElement {a.descendants(matching:.any).matching(identifier:id).firstMatch}
    private func reveal(_ a:XCUIApplication,label:String)->XCUIElement {
        let e=a.buttons.matching(NSPredicate(format:"label CONTAINS %@",label)).firstMatch
        for _ in 0..<12 {if e.exists && e.isHittable {return e};a.swipeUp()};return e
    }
    private func capture(_ name:String) {let x=XCTAttachment(screenshot:XCUIScreen.main.screenshot());x.name=name;x.lifetime = .keepAlways;add(x)}
}
