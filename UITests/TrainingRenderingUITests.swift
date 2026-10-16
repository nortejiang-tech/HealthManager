import XCTest

/// Reachability and visual evidence in normal, dark and accessibility text modes.
/// The development QA simulator is populated separately with explicitly synthetic data.
final class TrainingRenderingUITests: XCTestCase {
    func test_trainingEvidenceAndTrendsRemainReachableAcrossDisplayModes() throws {
        continueAfterFailure = false
        // Appearance is set on the simulator itself before this test. App launch
        // defaults do not reliably change UIKit's actual light/dark traits.
        let appearance = ProcessInfo.processInfo.environment["TRAINING_QA_APPEARANCE"] ?? "light"
        let modes: [(String, [String])] = appearance == "dark" ? [("dark", [])] : [
            ("light", []),
            ("large", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        ]
        for (name, arguments) in modes {
            let app = XCUIApplication()
            app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"] + arguments
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["锻炼"].waitForExistence(timeout: 15))
            app.tabBars.buttons["锻炼"].tap()
            let score = app.descendants(matching: .any).matching(identifier: "training-readiness-score").firstMatch
            XCTAssertTrue(score.waitForExistence(timeout: 15))
            screenshot("training-\(name)-overview")
            app.buttons["training-method"].tap()
            XCTAssertTrue(app.navigationBars["计算依据与可信度"].waitForExistence(timeout: 5))
            screenshot("training-\(name)-method")
            app.buttons["training-method-done"].tap()
            for (index, title) in ["跑步表现", "训练负荷 · 参考", "恢复趋势", "心肺与身体"].enumerated() {
                let heading = app.staticTexts[title].firstMatch
                for _ in 0..<16 {
                    if heading.exists && heading.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(heading.exists && heading.isHittable, "\(name): cannot reach \(title)")
                screenshot("training-\(name)-\(index)-trend")
            }
            app.terminate()
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
