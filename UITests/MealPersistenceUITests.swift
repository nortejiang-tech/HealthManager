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

        let notesElement = app.descendants(matching: .any)["meal-edit-notes"]
        XCTAssertTrue(notesElement.waitForExistence(timeout: 2))
        notesElement.tap()
        notesElement.typeText(uniqueMarker)

        app.buttons["meal-edit-save"].tap()

        let markerText = app.staticTexts[uniqueMarker]
        let markerButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", uniqueMarker)).firstMatch
        let markerCreated = markerText.waitForExistence(timeout: 4) || markerButton.waitForExistence(timeout: 4)
        XCTAssertTrue(markerCreated)

        XCTAssertTrue(markerButton.waitForExistence(timeout: 5))
        markerButton.tap()

        XCTAssertTrue(app.navigationBars["编辑餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        XCTAssertTrue(scrollToElement(withId: "meal-edit-notes", in: app))

        XCTAssertEqual(app.textFields["meal-item-name-0"].value as? String, "手工鸡排")
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "120")
        let notesReloadedElement = app.descendants(matching: .any)["meal-edit-notes"]
        XCTAssertEqual(notesReloadedElement.value as? String, uniqueMarker)

        app.buttons["meal-edit-cancel"].tap()

        cleanupMeal(with: uniqueMarker, in: app)
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

    private func scrollToElement(withId id: String, in app: XCUIApplication, attempts: Int = 10) -> Bool {
        let target = app.descendants(matching: .any)[id]

        for _ in 0..<attempts {
            if target.exists && target.isHittable {
                return true
            }
            if target.exists && target.waitForExistence(timeout: 0.15) && target.isHittable {
                return true
            }
            swipeFormUp(in: app)
        }
        return target.waitForExistence(timeout: 1) && target.isHittable
    }

    private func swipeFormUp(in app: XCUIApplication) {
        let collection = app.collectionViews.firstMatch
        if collection.exists {
            collection.swipeUp()
            return
        }

        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
        }
    }
}
