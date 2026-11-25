import XCTest

/// Review screen with the seeded demo import (`-uiTestInMemory -uiTestSeed`).
final class ReviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func openSeededReview(_ app: XCUIApplication, extraArguments: [String] = []) {
        app.launchArguments = ["-uiTestInMemory", "-uiTestSeed"] + extraArguments
        app.launch()
        let subject = app.buttons["subject-Biologie"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        let row = app.buttons["importRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(openCount(app).waitForExistence(timeout: 10))
    }

    /// The "Noch X Stellen offen" header; its accessibility value is the number.
    @MainActor
    private func openCount(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "reviewOpenCount").firstMatch
    }

    /// On iPhone (compact width) the text and image views are switched with a segmented control.
    @MainActor
    private func showMode(_ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["modePicker"]
        if picker.exists { picker.buttons[name].tap() }
    }

    @MainActor
    func testSelectingTextLineSelectsImageOverlayAndCorrectionClosesOpenPoint() throws {
        let app = XCUIApplication()
        openSeededReview(app)

        let counter = openCount(app)
        XCTAssertEqual(counter.value as? String, "1")

        // Tap line 2 (the uncertain one) in the text view …
        showMode("Text", in: app)
        let textLine = app.buttons["reviewLine-2"]
        XCTAssertTrue(textLine.waitForExistence(timeout: 5))
        textLine.tap()
        XCTAssertTrue(textLine.isSelected)

        // … and see it selected in the image.
        showMode("Bild", in: app)
        let imageLine = app.buttons["imageLine-2"]
        XCTAssertTrue(imageLine.waitForExistence(timeout: 5))
        XCTAssertTrue(imageLine.isSelected)
        XCTAssertEqual(imageLine.value as? String, "ausgewählt")
        XCTAssertFalse(app.buttons["imageLine-1"].isSelected)

        // Correct it: the recognizer's suggestion is the first candidate; tapping it fills the text field.
        app.buttons["correctLineButton"].tap()
        let field = app.textFields["correctionTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Chlorophyl ist der grune Blattfarbstoff")
        let candidate = app.buttons["candidate-0"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        XCTAssertEqual(field.value as? String, "Chlorophyll ist der grüne Blattfarbstoff")
        app.buttons["saveCorrectionButton"].tap()

        XCTAssertTrue(openCount(app).waitForExistence(timeout: 5))
        XCTAssertEqual(openCount(app).value as? String, "0")

        showMode("Text", in: app)
        let corrected = app.buttons["reviewLine-2"]
        XCTAssertTrue(corrected.waitForExistence(timeout: 5))
        XCTAssertEqual(corrected.label, "Zeile 3: Chlorophyll ist der grüne Blattfarbstoff. Von dir korrigiert.")
    }

    @MainActor
    func testTypedCorrectionReplacesTheText() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        showMode("Text", in: app)
        app.buttons["reviewLine-0"].tap()
        app.buttons["correctLineButton"].tap()
        let field = app.textFields["correctionTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fotosynthese")
        // Clear reliably: one delete per character instead of relying on the selection menu.
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText("Photosynthese")
        app.buttons["saveCorrectionButton"].tap()

        showMode("Text", in: app)
        let line = app.buttons["reviewLine-0"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.hasPrefix("Zeile 1: Photosynthese."), "Label: \(line.label)")
        XCTAssertTrue(line.label.contains("Von dir korrigiert."), "Label: \(line.label)")
    }

    @MainActor
    func testHighlightsAreAnnouncedForVoiceOver() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        showMode("Text", in: app)
        let line = app.buttons["reviewLine-1"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains("Chloroplasten, Textmarker"), "Label: \(line.label)")
    }

    @MainActor
    func testVersionsAndReRecognizeAreReachable() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        XCTAssertTrue(app.buttons["reRecognizeButton"].exists)
        app.buttons["versionsButton"].tap()
        XCTAssertTrue(app.staticTexts["Version 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["aktuell"].exists)
        // Only one version: nothing to restore.
        XCTAssertFalse(app.buttons["restoreVersionButton"].exists)
    }

    /// Needs two versions of the page, which a real re-recognition would create with Vision; the seed
    /// (`-uiTestSeedVersions`) stores the second one through the same repository calls instead.
    @MainActor
    func testRestoringAnOlderVersionBringsBackItsText() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestSeedVersions"])
        showMode("Text", in: app)
        let firstLine = app.buttons["reviewLine-0"]
        XCTAssertTrue(firstLine.waitForExistence(timeout: 5))
        XCTAssertTrue(firstLine.label.hasPrefix("Zeile 1: Fotosynthese (überarbeitet)."), "Label: \(firstLine.label)")

        app.buttons["versionsButton"].tap()
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Version 1"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "aktuell").count, 1)
        // Only the older version offers "Wiederherstellen".
        XCTAssertEqual(app.buttons.matching(identifier: "restoreVersionButton").count, 1)
        app.buttons["restoreVersionButton"].tap()

        // The sheet closes and the page shows the text of version 1 again.
        XCTAssertTrue(app.buttons["versionsButton"].waitForExistence(timeout: 5))
        showMode("Text", in: app)
        let restored = app.buttons["reviewLine-0"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.label.hasPrefix("Zeile 1: Fotosynthese."), "Label: \(restored.label)")
        XCTAssertFalse(restored.label.contains("überarbeitet"), "Label: \(restored.label)")

        // Version 1 is now the current one, version 2 can be restored in turn.
        app.buttons["versionsButton"].tap()
        XCTAssertTrue(app.staticTexts["Version 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "aktuell").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "restoreVersionButton").count, 1)
    }

    // MARK: Digital page (text layer, PDF, copy)

    /// The page image element; its accessibility value is the shown layer.
    @MainActor
    private func pageImage(_ app: XCUIApplication) -> XCUIElement {
        app.images["pageImageContent"].firstMatch
    }

    @MainActor
    private func waitForValue(_ expected: String, of element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the QuickLook preview of a PDF and closes it again (by the identifier of its close button; the label
    /// is localized and "Fertig" of the versions sheet must not be confused with it).
    @MainActor
    private func dismissQuickLook(_ app: XCUIApplication) {
        let done = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "QuickLook wurde nicht angezeigt")
        done.tap()
    }

    @MainActor
    func testLayerPickerSwitchesToTextLayerAndKeepsLineSelection() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        showMode("Bild", in: app)

        let picker = app.segmentedControls["pageLayerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.buttons["Handschrift"].exists && picker.buttons["Textebene"].exists)
        let image = pageImage(app)
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(image.value as? String, "Handschrift")

        picker.buttons["Textebene"].tap()
        XCTAssertTrue(waitForValue("Textebene", of: image), "Value: \(String(describing: image.value))")

        // Tapping a line still selects it, and the line actions appear.
        let imageLine = app.buttons["imageLine-2"]
        XCTAssertTrue(imageLine.waitForExistence(timeout: 5))
        imageLine.tap()
        XCTAssertTrue(imageLine.isSelected)
        XCTAssertTrue(app.buttons["copyLineButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["correctLineButton"].exists)

        // Back to the handwriting; the selection stays.
        picker.buttons["Handschrift"].tap()
        XCTAssertTrue(waitForValue("Handschrift", of: image))
        XCTAssertTrue(app.buttons["imageLine-2"].isSelected)
    }

    @MainActor
    func testCopyButtonOnlyShowsForASelectedLine() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        showMode("Text", in: app)
        XCTAssertFalse(app.buttons["copyLineButton"].exists)
        let line = app.buttons["reviewLine-1"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.tap()
        XCTAssertTrue(app.buttons["copyLineButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["copyLineButton"].label, "Text kopieren")
    }

    @MainActor
    func testDigitalPDFOpensInQuickLook() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        let button = app.buttons["digitalPDFButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(button.label, "Als PDF ansehen")
        button.tap()
        dismissQuickLook(app)
        XCTAssertTrue(app.buttons["digitalPDFButton"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testVersionOffersItsOwnPDF() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestSeedVersions"])
        app.buttons["versionsButton"].tap()
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "versionPDFButton").count, 2)
        app.buttons.matching(identifier: "versionPDFButton").element(boundBy: 1).tap()
        dismissQuickLook(app)
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 10))
    }
}
