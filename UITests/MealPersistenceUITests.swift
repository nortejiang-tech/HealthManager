import XCTest

final class MealPersistenceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_invalidParentSummarySaveKeepsEditorOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        app.tabBars.buttons["饮食"].tap()
        XCTAssertTrue(
            app.navigationBars["饮食"].waitForExistence(timeout: 5),
            "饮食标签未打开"
        )

        app.buttons["diet-add-meal"].tap()
        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))

        XCTAssertTrue(scrollToElement(withId: "meal-edit-calories", in: app))
        app.textFields["meal-edit-calories"].tap()
        app.textFields["meal-edit-calories"].typeText("abc")
        app.buttons["meal-edit-save"].tap()

        XCTAssertTrue(app.staticTexts["meal-edit-error"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["添加餐次"].exists)

        app.buttons["meal-edit-cancel"].tap()
    }

    func test_manualItemRoundTripRemainsOnReloadThenCleanup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        app.tabBars.buttons["饮食"].tap()
        let uniqueMarker = "uitest-\(UUID().uuidString)"
        registerTeardownCleanup(for: uniqueMarker, in: app)

        app.buttons["diet-add-meal"].tap()
        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))

        XCTAssertTrue(scrollToElement(withId: "meal-edit-add-item", in: app))
        app.buttons["meal-edit-add-item"].tap()

        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        app.textFields["meal-item-name-0"].tap()
        app.textFields["meal-item-name-0"].typeText("手工鸡排")

        XCTAssertTrue(scrollToElement(withId: "meal-item-grams-0", in: app))
        app.textFields["meal-item-grams-0"].tap()
        app.textFields["meal-item-grams-0"].typeText("120")

        let evidenceToggle = app.buttons["meal-item-evidence-toggle-0"]
        XCTAssertTrue(scrollToElement(withId: "meal-item-evidence-toggle-0", in: app))
        XCTAssertTrue(evidenceToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(evidenceToggle.label.contains("手工录入"))

        typeTextAndAssert(uniqueMarker, inFieldWithId: "meal-edit-notes", in: app)

        app.buttons["meal-edit-save"].tap()

        let markerText = app.staticTexts[uniqueMarker]
        let markerButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", uniqueMarker)).firstMatch
        let markerCreated = markerText.waitForExistence(timeout: 4) || markerButton.waitForExistence(timeout: 4)
        XCTAssertTrue(markerCreated)

        XCTAssertTrue(markerButton.waitForExistence(timeout: 5))
        markerButton.tap()

        XCTAssertTrue(app.navigationBars["编辑餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))

        XCTAssertEqual(app.textFields["meal-item-name-0"].value as? String, "手工鸡排")
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "120")

        let evidenceToggleAfterSave = app.buttons["meal-item-evidence-toggle-0"]
        XCTAssertTrue(scrollToElement(withId: "meal-item-evidence-toggle-0", in: app))
        XCTAssertTrue(evidenceToggleAfterSave.waitForExistence(timeout: 2))
        XCTAssertTrue(evidenceToggleAfterSave.label.contains("手工录入"))
        evidenceToggleAfterSave.tap()
        XCTAssertEqual(evidenceToggleAfterSave.value as? String, "已展开")
        XCTAssertTrue(
            scrollToElement(
                withId: "meal-item-evidence-coverage-0",
                in: app,
                requiresHitTesting: false
            )
        )
        XCTAssertTrue(app.staticTexts["meal-item-evidence-coverage-0"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["meal-item-evidence-coverage-0"].label, "营养字段：0/4 已记录")
        XCTAssertTrue(app.staticTexts["meal-item-evidence-preparation-0"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["meal-item-evidence-preparation-0"].label.contains("未标注"))
        XCTAssertTrue(app.staticTexts["meal-item-evidence-unknown-0"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["meal-item-evidence-revision-0"].label, "原始手工录入")
        attachScreenshot(named: "meal-item-evidence-expanded", from: app)

        XCTAssertTrue(
            scrollToElement(
                withId: "meal-item-evidence-caution-0",
                in: app,
                requiresHitTesting: false
            )
        )
        XCTAssertEqual(
            app.staticTexts["meal-item-evidence-caution-0"].label,
            "此条目由你手工录入；未附加独立数据来源。"
        )
        XCTAssertTrue(scrollToElement(withId: "meal-edit-notes", in: app))
        XCTAssertEqual(app.textFields["meal-edit-notes"].value as? String, uniqueMarker)

        app.buttons["meal-edit-cancel"].tap()

        cleanupMeal(with: uniqueMarker, in: app)
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func cleanupMeal(with marker: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()

        let deleteButton = app.buttons["删除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5))
    }

    private func registerTeardownCleanup(for marker: String, in app: XCUIApplication) {
        addTeardownBlock { [weak self] in
            guard let self else { return }
            self.returnToDietList(for: app)
            self.deleteMealIfPresent(for: marker, in: app)
        }
    }

    private func deleteMealIfPresent(for marker: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        guard row.waitForExistence(timeout: 1) else { return }
        row.swipeLeft()

        let deleteButton = app.buttons["删除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
        guard deleteButton.exists else { return }
        deleteButton.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5))
    }

    private func returnToDietList(for app: XCUIApplication) {
        if app.buttons["meal-edit-cancel"].waitForExistence(timeout: 0.5) {
            app.buttons["meal-edit-cancel"].tap()
        }
        if app.navigationBars["复用餐次"].waitForExistence(timeout: 0.5) {
            let cancelButton = app.navigationBars["复用餐次"].buttons["取消"]
            if cancelButton.exists {
                cancelButton.tap()
            }
        }
        if app.tabBars.buttons["饮食"].waitForExistence(timeout: 0.5) {
            app.tabBars.buttons["饮食"].tap()
        }
    }

    private func typeTextAndAssert(_ text: String, inFieldWithId id: String, in app: XCUIApplication) {
        XCTAssertTrue(scrollToElement(withId: id, in: app))
        let element = app.textFields[id]
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        element.tap()
        element.typeText(text)
        XCTAssertEqual(element.value as? String, text)
    }

    private func scrollToElement(
        withId id: String,
        in app: XCUIApplication,
        attempts: Int = 18,
        requiresHitTesting: Bool = true
    ) -> Bool {
        for _ in 0..<attempts {
            let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if target.waitForExistence(timeout: 0.25),
               isFullyVisible(target, in: app),
               !requiresHitTesting || target.isHittable {
                return true
            }
            app.swipeUp()
        }
        let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
        return target.waitForExistence(timeout: 1)
            && isFullyVisible(target, in: app)
            && (!requiresHitTesting || target.isHittable)
    }

    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let bounds = app.frame
        let topBoundary = app.navigationBars.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .map { $0.frame.maxY }
            .max() ?? bounds.minY
        let keyboardBoundary = app.keyboards.firstMatch.exists
            ? app.keyboards.firstMatch.frame.minY
            : bounds.maxY
        let frame = element.frame
        let bottomBoundary = min(bounds.maxY, keyboardBoundary)
        return frame.minY >= topBoundary + 4 && frame.maxY <= bottomBoundary - 12
    }
}
