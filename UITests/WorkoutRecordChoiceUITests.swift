import XCTest

/// Dedicated simulator fixture: two synthetic records for one workout; never run on owner data.
final class WorkoutRecordChoiceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testChooseCancelSaveRestartAndRestoreAutomatic() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic simulator only")
#else
        let app = launch()
        enterDetails(app)
        reveal(app,"workout-source-picker").tap()
        reveal(app,"workout-choice-auto").tap(); item(app,"workout-choice-save").tap()
        waitForEditorToClose(app)
        reveal(app,"workout-source-picker").tap()
        reveal(app,"workout-choice-choice-ui-apple").tap(); item(app,"workout-choice-cancel").tap()
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("自动"))
        reveal(app,"workout-source-picker").tap()
        reveal(app,"workout-choice-choice-ui-apple").tap(); capture("workout-choice-apple-selected")
        item(app,"workout-choice-save").tap()
        waitForEditorToClose(app)
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("Apple Watch"))
        capture("workout-choice-apple-effective")
        app.terminate(); app.launch(); enterDetails(app)
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("手动"))
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("Apple Watch"))
        reveal(app,"workout-source-picker").tap()
        reveal(app,"workout-choice-choice-ui-garmin").tap(); item(app,"workout-choice-save").tap()
        waitForEditorToClose(app)
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("Garmin"))
        reveal(app,"workout-source-picker").tap()
        reveal(app,"workout-choice-auto").tap(); item(app,"workout-choice-save").tap()
        waitForEditorToClose(app)
        XCTAssertTrue(item(app,"workout-source-picker").label.contains("自动"))
        app.terminate()
#endif
    }
    func testLargeTextChoiceSheetCanCancelWithoutChangingRecord() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic simulator only")
#else
        let app=launch(large:true); enterDetails(app)
        reveal(app,"workout-source-picker").tap()
        XCTAssertTrue(app.navigationBars["计入记录"].waitForExistence(timeout:5))
        reveal(app,"workout-choice-choice-ui-apple").tap();capture("workout-choice-large")
        item(app,"workout-choice-cancel").tap()
        XCTAssertTrue(app.navigationBars["运动详情"].waitForExistence(timeout:5))
        app.terminate()
#endif
    }
    private func launch(large:Bool=false)->XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["-HM_DEBUG_BYPASS_ONBOARDING","-hm.display.mode.v1",large ? "classic" : "cards","-llm.enabled","NO"]
        if large {app.launchArguments += ["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]}
        app.launch();XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout:20));return app
    }
    private func enterDetails(_ app:XCUIApplication) {
        app.tabBars.buttons["锻炼"].tap()
        let link=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","training-session-choice-ui-")).firstMatch
        for _ in 0..<15 { if link.exists && link.isHittable {break};app.swipeUp() }
        XCTAssertTrue(link.exists && link.isHittable);link.tap()
        waitForEditorToClose(app)
        XCTAssertTrue(item(app,"workout-source-picker").waitForExistence(timeout:15))
    }
    private func waitForEditorToClose(_ app:XCUIApplication) {
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.navigationBars["计入记录"])
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:15),.completed)
        XCTAssertTrue(app.navigationBars["运动详情"].exists)
    }
    private func item(_ app:XCUIApplication,_ id:String)->XCUIElement {app.descendants(matching:.any).matching(identifier:id).firstMatch}
    private func reveal(_ app:XCUIApplication,_ id:String)->XCUIElement {
        let target=item(app,id)
        for _ in 0..<15 {if target.exists && target.isHittable{return target};app.swipeUp()}
        XCTAssertTrue(target.exists && target.isHittable);return target
    }
    private func capture(_ name:String) {let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
}
