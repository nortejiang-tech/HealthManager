import XCTest

final class SyncLifecycleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchPublishesLocalDashboardAndKeepsManualDiagnosticsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        let startedAt = ProcessInfo.processInfo.systemUptime
        app.launch()

        let dashboard = app.descendants(matching: .any)
            .matching(identifier: "dashboard-screen")
            .firstMatch
        XCTAssertTrue(
            dashboard.waitForExistence(timeout: 20),
            "Cold launch must publish the local dashboard without waiting for a manual sync."
        )
        let visibleAt = ProcessInfo.processInfo.systemUptime
        print("SIMULATOR_LOCAL_DASHBOARD_VISIBLE_SECONDS=\(visibleAt - startedAt)")
        XCTAssertTrue(app.tabBars.buttons["趋势"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "dashboard-edit-cards")
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        app.tabBars.buttons["更多"].tap()
        let syncCenter = app.descendants(matching: .any)
            .matching(identifier: "more-sync-center")
            .firstMatch
        XCTAssertTrue(syncCenter.waitForExistence(timeout: 8))
        syncCenter.tap()
        XCTAssertTrue(app.navigationBars["同步中心"].waitForExistence(timeout: 8))

        let knownStatusLabels = [
            "空闲",
            "等待授权检查",
            "等待设备解锁",
            "正在读取 Apple 健康",
            "正在更新本地指标",
            "本地指标待更新",
            "已检查，无新增",
            "部分完成",
            "本轮未完成"
        ]
        XCTAssertTrue(
            knownStatusLabels.contains { app.staticTexts[$0].exists },
            "Sync Center must expose a concrete state instead of an unbounded generic spinner."
        )

        // 「立即同步」位于历史回补区块之下：List 离屏行不进无障碍树，需滚动到可见。
        let syncNowButton = app.buttons["立即同步"].firstMatch
        var scrolls = 0
        while !syncNowButton.exists && scrolls < 4 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(syncNowButton.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sync-lifecycle-cold-launch-and-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
