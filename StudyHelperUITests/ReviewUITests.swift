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
}
