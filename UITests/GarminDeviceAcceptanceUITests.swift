import XCTest

/// Physical-device read-only navigation and external App handoff. No key input,
/// record editing, account writes or artificial health fixtures.
final class GarminDeviceAcceptanceUITests: XCTestCase {
    func testMissingNativeAppShowsMessageAndStaysInHealthManager() throws {
#if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING", "-hm.display.mode.v1", "cards"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout: 20))
        app.tabBars.buttons["锻炼"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "garmin-card-bodyBattery").firstMatch.waitForExistence(timeout: 20))
        reveal("garmin-readiness-unavailable", in: app).tap()
        reveal("garmin-readiness-connect", in: app).tap()
        XCTAssertTrue(app.alerts["无法打开 Garmin Connect"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        app.alerts.buttons["好"].tap()
#else
        throw XCTSkip("Missing-app fallback belongs to the isolated simulator")
#endif
    }

    func testPhysicalTrainingAndNativeConnectHandoff() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the user's installed Garmin Connect on physical iPhone")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout: 20))
        app.tabBars.buttons["锻炼"].tap()
        let card = app.descendants(matching: .any).matching(identifier: "garmin-card-bodyBattery").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let readiness = reveal("garmin-readiness-unavailable", in: app)
        readiness.tap()
        let connect = reveal("garmin-readiness-connect", in: app)
        XCTAssertEqual(app.state, .runningForeground)
        connect.tap()
        let garmin = XCUIApplication(bundleIdentifier: "com.garmin.connect.mobile")
        XCTAssertTrue(garmin.wait(for: .runningForeground, timeout: 15), "The actual button must foreground Garmin Connect")
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout: 15))
#endif
    }

    private func reveal(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<16 {
            if target.exists && target.isHittable { return target }
            app.swipeUp()
        }
        return target
    }
}
