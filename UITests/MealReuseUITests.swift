import XCTest

final class MealReuseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_reuseWholeMealCanEnterEditorAndCancelWithoutAddingRecord() throws {
        let app = launchDietApp()
        let marker = "uitest-reuse-whole-\(UUID().uuidString)"
        let itemName = "整餐菜品-\(UUID().uuidString)"
        registerTargetedCleanup(markers: [marker], in: app)

        addManualMeal(in: app, itemName: itemName, grams: "120", note: marker)
        let sourceMealId = try XCTUnwrap(
            mealRowId(for: marker, in: app),
            "源餐未能在列表找到: \(marker)"
        )
        let rowCountBeforeReuse = mealRows(in: app).count

        app.buttons["diet-reuse-meal"].tap()
        XCTAssertTrue(app.navigationBars["复用餐次"].waitForExistence(timeout: 5))
        attachScreenshot(named: "reuse-whole-list", from: app)

        let reuseWholeButton = app.buttons["meal-reuse-whole-\(sourceMealId)"]
        XCTAssertTrue(reuseWholeButton.waitForExistence(timeout: 5))
        reuseWholeButton.tap()

        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        attachScreenshot(named: "reuse-whole-editor", from: app)
        XCTAssertEqual(app.textFields["meal-item-name-0"].value as? String, itemName)
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "120")

        app.buttons["meal-edit-cancel"].tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
        XCTAssertEqual(mealRows(in: app).count, rowCountBeforeReuse)

        cleanupMealRequiringPresence(with: marker, in: app)
        assertNoRows(with: marker, in: app)
    }

    func test_reuseSelectedItemsOnlyAndSaveCopyWithoutSourceNotes() throws {
        let app = launchDietApp()
        let sourceMarker = "uitest-reuse-source-\(UUID().uuidString)"
        let copyMarker = "uitest-reuse-copy-\(UUID().uuidString)"
        let mainItemName = "主菜-\(UUID().uuidString)"
        let extraItemName = "副菜-\(UUID().uuidString)"
        registerTargetedCleanup(markers: [sourceMarker, copyMarker], in: app)

        addManualMeal(
            in: app,
            itemName: mainItemName,
            grams: "80",
            note: sourceMarker,
            extraName: extraItemName,
            extraGrams: "40"
        )
        let sourceMealId = try XCTUnwrap(
            mealRowId(for: sourceMarker, in: app),
            "源餐未能在列表找到: \(sourceMarker)"
        )

        app.buttons["diet-reuse-meal"].tap()
        XCTAssertTrue(app.navigationBars["复用餐次"].waitForExistence(timeout: 5))

        let selectButton = app.buttons["meal-reuse-select-\(sourceMealId)"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()
        attachScreenshot(named: "reuse-item-selection", from: app)

        let confirmButton = app.buttons["meal-reuse-item-confirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        XCTAssertFalse(confirmButton.isEnabled)

        let mainItemToggle = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "meal-reuse-item-toggle-",
                mainItemName
            )
        ).firstMatch
        XCTAssertTrue(mainItemToggle.waitForExistence(timeout: 5))
        mainItemToggle.tap()
        XCTAssertTrue(confirmButton.isEnabled)
        confirmButton.tap()

        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        XCTAssertEqual(app.textFields["meal-item-name-0"].value as? String, mainItemName)
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "80")
        XCTAssertFalse(app.textFields["meal-item-name-1"].exists)

        XCTAssertTrue(scrollToElement(withId: "meal-edit-notes", in: app))
        let notesField = app.textFields["meal-edit-notes"]
        XCTAssertNotEqual(notesField.value as? String, sourceMarker)
        typeTextAndAssert(copyMarker, inFieldWithId: "meal-edit-notes", in: app)

        let saveCopyButton = app.buttons["meal-edit-save"]
        XCTAssertTrue(saveCopyButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveCopyButton.isEnabled)
        saveCopyButton.tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))

        let copyRow = mealRow(matching: copyMarker, in: app)
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5))
        copyRow.tap()

        XCTAssertTrue(app.navigationBars["编辑餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        XCTAssertEqual(app.textFields["meal-item-name-0"].value as? String, mainItemName)
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "80")
        XCTAssertFalse(app.textFields["meal-item-name-1"].exists)
        XCTAssertTrue(scrollToElement(withId: "meal-edit-notes", in: app))
        let notesReloadedField = app.textFields["meal-edit-notes"]
        XCTAssertEqual(
            notesReloadedField.value as? String,
            copyMarker
        )
        app.buttons["meal-edit-cancel"].tap()

        cleanupMealRequiringPresence(with: sourceMarker, in: app)
        cleanupMealRequiringPresence(with: copyMarker, in: app)
        assertNoRows(with: sourceMarker, in: app)
        assertNoRows(with: copyMarker, in: app)
    }

    func test_commonGramsSuggestionAppearsForExactNameAndPreparationAndFillsGrams() throws {
        let app = launchDietApp()
        let marker = "uitest-reuse-grams-\(UUID().uuidString)"
        let itemName = "常用克数-\(UUID().uuidString)"
        registerTargetedCleanup(markers: [marker], in: app)

        addManualMeal(in: app, itemName: itemName, grams: "150", note: marker)

        app.buttons["diet-add-meal"].tap()
        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(withId: "meal-edit-add-item", in: app))
        app.buttons["meal-edit-add-item"].tap()

        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        app.textFields["meal-item-name-0"].tap()
        app.textFields["meal-item-name-0"].typeText(itemName)

        let suggestion = app.buttons["meal-item-common-grams-0-150"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 6))
        attachScreenshot(named: "common-grams-suggestion", from: app)
        suggestion.tap()
        XCTAssertEqual(app.textFields["meal-item-grams-0"].value as? String, "150")

        app.buttons["meal-edit-cancel"].tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
        cleanupMealRequiringPresence(with: marker, in: app)
        assertNoRows(with: marker, in: app)
    }

    private func launchDietApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HM_DEBUG_BYPASS_ONBOARDING"]
        app.launch()

        app.tabBars.buttons["饮食"].tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
        return app
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func registerTargetedCleanup(markers: [String], in app: XCUIApplication) {
        addTeardownBlock { [self] in
            ensureDietListVisible(in: app)
            for marker in markers {
                cleanupMealIfPresent(with: marker, in: app)
                assertNoRows(with: marker, in: app)
            }
        }
    }

    private func addManualMeal(
        in app: XCUIApplication,
        itemName: String,
        grams: String,
        note: String,
        extraName: String? = nil,
        extraGrams: String? = nil
    ) {
        app.buttons["diet-add-meal"].tap()
        XCTAssertTrue(app.navigationBars["添加餐次"].waitForExistence(timeout: 5))

        XCTAssertTrue(scrollToElement(withId: "meal-edit-add-item", in: app))
        app.buttons["meal-edit-add-item"].tap()

        XCTAssertTrue(scrollToElement(withId: "meal-item-name-0", in: app))
        app.textFields["meal-item-name-0"].tap()
        app.textFields["meal-item-name-0"].typeText(itemName)
        app.textFields["meal-item-grams-0"].tap()
        app.textFields["meal-item-grams-0"].typeText(grams)

        if let extraName, let extraGrams {
            XCTAssertTrue(scrollToElement(withId: "meal-edit-add-item", in: app))
            app.buttons["meal-edit-add-item"].tap()
            XCTAssertTrue(scrollToElement(withId: "meal-item-name-1", in: app))
            app.textFields["meal-item-name-1"].tap()
            app.textFields["meal-item-name-1"].typeText(extraName)
            app.textFields["meal-item-grams-1"].tap()
            app.textFields["meal-item-grams-1"].typeText(extraGrams)
        }

        typeTextAndAssert(note, inFieldWithId: "meal-edit-notes", in: app)

        let saveButton = app.buttons["meal-edit-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
        XCTAssertTrue(mealRow(matching: note, in: app).waitForExistence(timeout: 5))
    }

    private func mealRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'meal-row-'"))
    }

    private func mealRow(matching marker: String, in app: XCUIApplication) -> XCUIElement {
        mealRows(in: app).matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch
    }

    private func mealRowId(for marker: String, in app: XCUIApplication) -> Int64? {
        let row = mealRow(matching: marker, in: app)
        guard row.waitForExistence(timeout: 8), row.identifier.hasPrefix("meal-row-") else {
            return nil
        }
        return Int64(row.identifier.replacingOccurrences(of: "meal-row-", with: ""))
    }

    private func cleanupMealRequiringPresence(with marker: String, in app: XCUIApplication) {
        ensureDietListVisible(in: app)
        let row = mealRow(matching: marker, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Cleanup failed: 未找到 \(marker)")
        guard row.exists else { return }
        delete(row: row, marker: marker, in: app)
    }

    private func cleanupMealIfPresent(with marker: String, in app: XCUIApplication) {
        let row = mealRow(matching: marker, in: app)
        guard row.waitForExistence(timeout: 1) else { return }
        delete(row: row, marker: marker, in: app)
    }

    private func delete(row: XCUIElement, marker: String, in app: XCUIApplication) {
        row.swipeLeft()
        let deleteButton = app.buttons["删除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3), "Cleanup failed: \(marker) 无删除按钮")
        guard deleteButton.exists else { return }
        deleteButton.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "Cleanup failed: \(marker) 删除后仍存在")
    }

    private func ensureDietListVisible(in app: XCUIApplication) {
        if app.state != .runningForeground {
            app.launch()
        }
        if app.buttons["meal-edit-cancel"].waitForExistence(timeout: 0.5) {
            app.buttons["meal-edit-cancel"].tap()
        }
        if app.navigationBars["复用餐次"].waitForExistence(timeout: 0.5) {
            let cancelButton = app.navigationBars["复用餐次"].buttons["取消"]
            if cancelButton.exists {
                cancelButton.tap()
            }
        }
        if app.tabBars.buttons["饮食"].waitForExistence(timeout: 2) {
            app.tabBars.buttons["饮食"].tap()
        }
        XCTAssertTrue(app.navigationBars["饮食"].waitForExistence(timeout: 5))
    }

    private func assertNoRows(with marker: String, in app: XCUIApplication) {
        XCTAssertEqual(mealRows(in: app).matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).count, 0)
    }

    private func scrollToElement(
        withId id: String,
        in app: XCUIApplication,
        attempts: Int = 18
    ) -> Bool {
        for _ in 0..<attempts {
            let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if target.waitForExistence(timeout: 0.25) && isFullyVisible(target, in: app) {
                return true
            }
            app.swipeUp()
        }
        let target = app.descendants(matching: .any).matching(identifier: id).firstMatch
        return target.waitForExistence(timeout: 1) && isFullyVisible(target, in: app)
    }

    private func typeTextAndAssert(_ text: String, inFieldWithId id: String, in app: XCUIApplication) {
        XCTAssertTrue(scrollToElement(withId: id, in: app))
        let element = app.textFields[id]
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        element.tap()
        element.typeText(text)
        XCTAssertEqual(element.value as? String, text)
    }

    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists && element.isHittable else { return false }
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
