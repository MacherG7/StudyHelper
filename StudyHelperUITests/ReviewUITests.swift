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

    /// The "Noch X Wörter offen" header; its accessibility value is the number.
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
        XCTAssertEqual(counter.value as? String, "2", "zwei unsichere Wörter: Chlorophyl und grune")

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

    /// Word-level review (D-044): only the two uncertain words are marked (not the whole line). One tap on a marked word
    /// opens its sheet with the best reading on top; "Übernehmen" corrects only that word, the other one stays marked
    /// and is confirmed from the image (one tap on its frame, no line selected first).
    @MainActor
    func testOneTapOnMarkedWordOpensSheetWithBestReading() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestMockAI"])
        XCTAssertEqual(openCount(app).value as? String, "2")

        showMode("Text", in: app)
        let line = app.buttons["reviewLine-2"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains("Unsichere Wörter: Chlorophyl, grune."), "Label: \(line.label)")
        XCTAssertFalse(app.buttons["reviewWord-0-0"].exists, "Zeile 1 hat keine Markierung")
        XCTAssertFalse(app.buttons["reviewLine-0"].label.contains("Unsicher"), "Label: \(app.buttons["reviewLine-0"].label)")
        XCTAssertFalse(app.buttons["wordChip-0"].exists, "keine zweite Reihe mit Wort-Schaltflächen unter der Zeile")
        let word = app.buttons["reviewWord-2-0"]
        XCTAssertTrue(word.exists)
        XCTAssertEqual(word.label, "Unsicheres Wort: Chlorophyl")
        XCTAssertTrue(app.buttons["reviewWord-2-3"].exists)
        XCTAssertFalse(line.isSelected)
        word.tap()

        // The sheet: the best reading is on top, the model's reading follows, the field holds the word as written.
        let best = app.buttons["applyBestButton"]
        XCTAssertTrue(best.waitForExistence(timeout: 10), "bester Vorschlag fehlt")
        XCTAssertEqual(best.label, "Chlorophyll übernehmen")
        let field = app.textFields["wordCorrectionField"]
        XCTAssertEqual(field.value as? String, "Chlorophyl")
        let further = app.buttons["wordSuggestion-0"]
        XCTAssertTrue(further.exists)
        XCTAssertEqual(further.label, "Chlorofyll, Vorschlag des Geräte-Modells")
        XCTAssertFalse(app.otherElements["wordCandidatesLoading"].exists)
        XCTAssertFalse(app.buttons["applyWordButton"].isEnabled, "ohne Änderung nichts zu übernehmen")
        best.tap()

        // One word less open; the other one is still marked and the line is not "corrected as a whole".
        XCTAssertTrue(waitForValue("1", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        XCTAssertFalse(app.buttons["reviewWord-2-0"].exists)
        XCTAssertTrue(app.buttons["reviewWord-2-3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reviewLine-2"].label.contains("Chlorophyll ist der grune Blattfarbstoff."), "Label: \(app.buttons["reviewLine-2"].label)")
        XCTAssertFalse(app.buttons["reviewLine-2"].isSelected, "das Wort zu öffnen wählt die Zeile nicht aus")

        // The same word in the image: one tap on its frame opens the sheet; confirm it as written.
        showMode("Bild", in: app)
        let frame = app.buttons["imageWord-2-3"]
        XCTAssertTrue(frame.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["imageWord-2-0"].exists)
        frame.tap()
        XCTAssertTrue(app.buttons["confirmWordButton"].waitForExistence(timeout: 5))
        app.buttons["confirmWordButton"].tap()
        XCTAssertTrue(waitForValue("0", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        XCTAssertFalse(app.buttons["imageWord-2-3"].exists)
    }

    /// "Nacheinander prüfen": the open words one after the other, every step is the word sheet and moves on.
    @MainActor
    func testWordsAreCheckedOneAfterTheOther() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestMockAI"])
        XCTAssertEqual(openCount(app).value as? String, "2")
        let start = app.buttons["startWordCheckButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        XCTAssertTrue(app.navigationBars["Wort 1 von 2"].waitForExistence(timeout: 10))
        let best = app.buttons["applyBestButton"]
        XCTAssertTrue(best.waitForExistence(timeout: 10))
        best.tap()

        // The second word follows without closing the sheet.
        XCTAssertTrue(app.navigationBars["Wort 2 von 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["skipWordButton"].exists)
        let confirm = app.buttons["confirmWordButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        XCTAssertTrue(waitForValue("0", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        XCTAssertFalse(start.exists, "nichts mehr offen: kein Knopf")
    }

    /// The best reading is computed in the background and shown next to the marked word as "→ word?"; one tap applies it.
    @MainActor
    func testQuickFixAppliesTheBestReadingWithoutOpeningTheWord() throws {
        let app = XCUIApplication()
        openSeededReview(app)
        showMode("Text", in: app)
        let fix = app.buttons["quickFix-2-0"]
        XCTAssertTrue(fix.waitForExistence(timeout: 10), "Vorschlag neben dem Wort fehlt")
        XCTAssertEqual(fix.label, "Vorschlag übernehmen: Chlorophyll")
        let second = app.buttons["quickFix-2-3"]
        XCTAssertTrue(second.exists)
        XCTAssertEqual(second.label, "Vorschlag übernehmen: grüne")
        fix.tap()

        XCTAssertTrue(waitForValue("1", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        XCTAssertFalse(app.buttons["reviewWord-2-0"].exists)
        XCTAssertFalse(app.buttons["quickFix-2-0"].exists)
        XCTAssertTrue(app.buttons["quickFix-2-3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["wordCorrectionField"].exists, "das Wort-Fenster blieb zu")
        XCTAssertTrue(app.buttons["reviewLine-2"].label.contains("Chlorophyll ist der grune Blattfarbstoff."), "Label: \(app.buttons["reviewLine-2"].label)")
    }

    /// Possible subject terms of the import: one banner with "Übernehmen"; adopting adds them to the subject, so that
    /// their marks disappear.
    @MainActor
    func testTermSuggestionBannerAdoptsTerms() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestUnknownWords", "chloroplasten,blattfarbstoff"])
        // Two recognizer words plus the two unknown words.
        XCTAssertEqual(openCount(app).value as? String, "4")
        let banner = app.descendants(matching: .any).matching(identifier: "termBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "Fachbegriff-Hinweis fehlt")
        let text = app.staticTexts["termBannerText"]
        XCTAssertTrue(text.label.contains("Chloroplasten"), "Text: \(text.label)")
        XCTAssertTrue(text.label.contains("Blattfarbstoff"), "Text: \(text.label)")
        app.buttons["adoptTermsButton"].tap()
        XCTAssertTrue(waitForValue("2", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        XCTAssertTrue(waitForDisappearance(of: banner), "Hinweis bleibt nach dem Übernehmen")
    }

    /// "Auswählen" lets the user adopt some of the terms; the banner can be dismissed.
    @MainActor
    func testTermSuggestionBannerSelectionAndDismissal() throws {
        let app = XCUIApplication()
        openSeededReview(app, extraArguments: ["-uiTestUnknownWords", "chloroplasten,blattfarbstoff"])
        XCTAssertTrue(app.buttons["selectTermsButton"].waitForExistence(timeout: 10))
        app.buttons["selectTermsButton"].tap()
        let toggle = app.switches["termToggle-1"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("0", of: toggle, timeout: 5), "Schalter: \(String(describing: toggle.value))")
        app.buttons["adoptSelectedTermsButton"].tap()
        // Only "Chloroplasten" was adopted: 3 places stay open.
        XCTAssertTrue(waitForValue("3", of: openCount(app), timeout: 10), "Zähler: \(String(describing: openCount(app).value))")
        let banner = app.descendants(matching: .any).matching(identifier: "termBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "der zweite Begriff ist noch vorgeschlagen")
        app.buttons["dismissTermsButton"].tap()
        XCTAssertTrue(waitForDisappearance(of: banner))
        XCTAssertEqual(openCount(app).value as? String, "3")
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

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
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
