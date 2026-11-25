import XCTest

/// Topics of the seeded subject "Biologie" (`-uiTestInMemory -uiTestSeed`, optionally `-uiTestSeedTopics`).
final class TopicsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func openSubject(_ app: XCUIApplication, withTopics: Bool) {
        app.launchArguments = ["-uiTestInMemory", "-uiTestSeed"] + (withTopics ? ["-uiTestSeedTopics"] : [])
        app.launch()
        let subject = app.buttons["subject-Biologie"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        XCTAssertTrue(app.buttons["addTopicButton"].waitForExistence(timeout: 5))
    }

    /// On iPhone (compact width) the panes are switched with a segmented control; on iPad the
    /// "Quelle" segment does not exist because the source text sits next to the editor.
    @MainActor
    private func showPane(_ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["topicPanePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let button = picker.buttons[name]
        if button.exists { button.tap() }
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func goBackToSubject(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["addTopicButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCreateTopicTakeOverLineAsKeyStatementAndConfirm() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: false)
        XCTAssertTrue(app.staticTexts["topicsEmptyHint"].exists)

        // The title is required: an empty title shows a message instead of creating a topic.
        app.buttons["addTopicButton"].tap()
        let field = app.textFields["topicTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["saveTopicButton"].tap()
        XCTAssertTrue(app.staticTexts["topicTitleValidation"].waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Zellatmung")
        app.buttons["saveTopicButton"].tap()

        // The new topic opens right away, as a draft.
        XCTAssertTrue(element(app, "topicDraftBadge").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "topicConfirmedBadge").exists)

        // Assign the page, then take over line 2 from the source panel.
        showPane("Quelle", in: app)
        // The empty state of the source panel offers the assignment (a ContentUnavailableView action).
        let assign = app.buttons["Seiten zuordnen"].firstMatch
        XCTAssertTrue(assign.waitForExistence(timeout: 5))
        assign.tap()
        let page = app.buttons["pagePickRow-0"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.tap()
        app.buttons["pageAssignmentDoneButton"].tap()

        let line = app.buttons["topicLine-1"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains("Ort: Chloroplasten"), "Label: \(line.label)")
        line.tap()
        XCTAssertTrue(line.isSelected)
        let takeOver = app.buttons["takeover-keyStatement"]
        XCTAssertTrue(takeOver.waitForExistence(timeout: 5))
        takeOver.tap()
        XCTAssertTrue(element(app, "takeoverConfirmation").waitForExistence(timeout: 5))

        // The entry is in the editor with its origin and the highlight of the original.
        showPane("Felder", in: app)
        showPane("Bearbeiten", in: app)
        let entry = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("Kernaussage: Ort: Chloroplasten"), "Label: \(entry.label)")
        XCTAssertTrue(entry.label.contains("Original aus dem Lernstoff"), "Label: \(entry.label)")
        XCTAssertTrue(entry.label.contains("Textmarker"), "Label: \(entry.label)")

        // Confirm: the badge changes, the button goes away.
        app.buttons["confirmTopicButton"].tap()
        XCTAssertTrue(element(app, "topicConfirmedBadge").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "topicDraftBadge").exists)
        XCTAssertFalse(app.buttons["confirmTopicButton"].exists)

        // The list shows the status, too.
        goBackToSubject(app)
        let row = app.buttons["topic-Zellatmung"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Bestätigt"), "Label: \(row.label)")
        XCTAssertTrue(row.label.contains("1 Eintrag"), "Label: \(row.label)")
    }

    @MainActor
    func testTappingAnEntryMarksItsPlaceInThePageImageAndEditingMakesItYourOwn() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        let row = app.buttons["topic-Fotosynthese"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Entwurf"), "Label: \(row.label)")
        row.tap()

        showPane("Prüfen", in: app)
        let entry = app.buttons["reviewEntry-0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("Herkunft: Original aus dem Lernstoff"), "Label: \(entry.label)")
        XCTAssertTrue(entry.label.contains("Im Original hervorgehoben: Textmarker, gelb"), "Label: \(entry.label)")
        XCTAssertFalse(element(app, "sourceMark").exists)

        entry.tap()
        let mark = element(app, "sourceMark")
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        XCTAssertEqual(mark.value as? String, "ausgewählt")
        XCTAssertTrue(entry.isSelected)

        // The mark sits on the line it stands for: line 2 of the seeded page is the area
        // x 0.10, y 0.20, width 0.55, height 0.05 of the page image. The page zooms to the mark
        // after tapping, so wait until mark and expected area agree.
        let page = app.images["Originalbild der Seite"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        var overlap = 0.0
        for _ in 0..<25 {
            let image = page.frame
            let expected = CGRect(
                x: image.minX + 0.10 * image.width, y: image.minY + 0.20 * image.height,
                width: 0.55 * image.width, height: 0.05 * image.height)
            let intersection = mark.frame.intersection(expected)
            overlap = intersection.isNull ? 0 : Double(intersection.width * intersection.height / (expected.width * expected.height))
            if overlap > 0.8 { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertGreaterThan(overlap, 0.8, "Die Markierung liegt nicht auf der Zeile (Überdeckung \(overlap)); Markierung \(mark.frame), Seite \(page.frame)")

        // Tapping again clears the marking.
        entry.tap()
        XCTAssertFalse(entry.isSelected)
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: element(app, "sourceMark"))
            || !element(app, "sourceMark").waitForExistence(timeout: 1))

        // Same launch: editing the entry in the editor makes it the user's own.
        showPane("Felder", in: app)
        showPane("Bearbeiten", in: app)
        let editorRow = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(editorRow.waitForExistence(timeout: 5))
        XCTAssertTrue(editorRow.label.contains("Original aus dem Lernstoff"), "Label: \(editorRow.label)")
        editorRow.tap()
        let field = app.textFields["entryTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(field, with: "Ort: Thylakoidmembran")
        app.buttons["saveEntryButton"].tap()

        let edited = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        XCTAssertTrue(edited.label.contains("Kernaussage: Ort: Thylakoidmembran"), "Label: \(edited.label)")
        XCTAssertTrue(edited.label.contains("von dir eingegeben"), "Label: \(edited.label)")
    }

    /// Rename, then delete (cancel first) in one launch: both only need the seeded topic list.
    @MainActor
    func testRenameAndDeleteTopic() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        let row = app.buttons["topic-Fotosynthese"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let rename = app.buttons["Umbenennen"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()

        let field = app.textFields["topicTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fotosynthese")
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText("Photosynthese")
        app.buttons["saveTopicButton"].tap()

        XCTAssertTrue(app.buttons["topic-Photosynthese"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["topic-Fotosynthese"].exists)

        // Deleting asks for confirmation; cancelling keeps the topic.
        app.buttons["topic-Photosynthese"].swipeLeft()
        app.buttons["Löschen"].firstMatch.tap()
        let alert = app.alerts["Thema löschen?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Abbrechen"].tap()
        XCTAssertTrue(app.buttons["topic-Photosynthese"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["topicsEmptyHint"].exists)

        // Delete for real (the row may still show its swipe buttons after cancelling).
        let delete = app.buttons["Löschen"].firstMatch
        if !delete.exists { app.buttons["topic-Photosynthese"].swipeLeft() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        app.buttons["confirmDeleteTopicButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["topicsEmptyHint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["topic-Photosynthese"].exists)
    }

    /// Replaces the text of a text field one character at a time (reliable, no selection menu).
    @MainActor
    private func replaceText(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText(text)
    }

    /// Opens the import, corrects line 2 ("Ort: Chloroplasten") to `text` and saves.
    @MainActor
    private func correctLineTwo(_ app: XCUIApplication, to text: String) {
        app.buttons["importRow"].firstMatch.tap()
        let picker = app.segmentedControls["modePicker"]
        if picker.waitForExistence(timeout: 10) { picker.buttons["Text"].tap() }
        let line = app.buttons["reviewLine-1"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.tap()
        app.buttons["correctLineButton"].tap()
        let field = app.textFields["correctionTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(field, with: text)
        app.buttons["saveCorrectionButton"].tap()
    }

    @MainActor
    func testCorrectedLineMarksTheEntryAndAdoptingUpdatesIt() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        correctLineTwo(app, to: "Ort: Stroma")

        let hint = element(app, "affectedTopicsHint")
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        let link = app.buttons["affectedTopic-Fotosynthese"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(element(app, "topicDraftBadge").waitForExistence(timeout: 5))

        // The entry says that its source changed and still shows the text from the time of taking it over.
        showPane("Prüfen", in: app)
        let entry = app.buttons["reviewEntry-0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("Quelle geändert"), "Label: \(entry.label)")
        XCTAssertTrue(entry.label.contains("Ort: Chloroplasten"), "Label: \(entry.label)")
        entry.tap()
        let adopt = app.buttons["adoptSourceButton"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ignoreSourceChangeButton"].exists)

        adopt.tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Ort: Stroma'").evaluate(with: entry)
            || entry.waitForExistence(timeout: 2))
        let updated = app.buttons["reviewEntry-0"]
        XCTAssertTrue(updated.label.contains("Kernaussage: Ort: Stroma"), "Label: \(updated.label)")
        XCTAssertFalse(updated.label.contains("Quelle geändert"), "Label: \(updated.label)")
        XCTAssertFalse(app.buttons["adoptSourceButton"].exists)
    }

    @MainActor
    func testIgnoringASourceChangeKeepsTheEntry() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        correctLineTwo(app, to: "Ort: Stroma")
        let link = app.buttons["affectedTopic-Fotosynthese"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()

        // The editor row carries the marker, the entry sheet the actions.
        showPane("Felder", in: app)
        showPane("Bearbeiten", in: app)
        let row = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Quelle geändert"), "Label: \(row.label)")
        row.tap()
        let ignore = app.buttons["ignoreSourceChangeButton"]
        XCTAssertTrue(ignore.waitForExistence(timeout: 5))
        ignore.tap()

        let after = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertTrue(after.label.contains("Ort: Chloroplasten"), "Label: \(after.label)")
        XCTAssertFalse(after.label.contains("Quelle geändert"), "Label: \(after.label)")
    }

    @MainActor
    func testRemovingTheSourceReferenceMakesTheEntryYourOwn() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        app.buttons["topic-Fotosynthese"].tap()
        showPane("Felder", in: app)
        showPane("Bearbeiten", in: app)
        let row = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Original aus dem Lernstoff"), "Label: \(row.label)")
        XCTAssertTrue(row.label.contains("Quelle: Fotosynthese.jpg"), "Label: \(row.label)")
        row.tap()
        let remove = app.buttons["Verweis auf die Quelle entfernen"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()

        // Without a source the text is no longer content taken from the learning material.
        let after = app.buttons["entryRow-keyStatement-0"]
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        XCTAssertTrue(after.label.contains("von dir eingegeben"), "Label: \(after.label)")
        XCTAssertFalse(after.label.contains("Original aus dem Lernstoff"), "Label: \(after.label)")
        XCTAssertFalse(after.label.contains("Quelle:"), "Label: \(after.label)")
    }

    @MainActor
    private func createTopic(_ app: XCUIApplication, title: String, confirm: Bool) {
        app.buttons["addTopicButton"].tap()
        let field = app.textFields["topicTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.buttons["saveTopicButton"].tap()
        XCTAssertTrue(element(app, "topicDraftBadge").waitForExistence(timeout: 5))
        if confirm {
            app.buttons["confirmTopicButton"].tap()
            XCTAssertTrue(element(app, "topicConfirmedBadge").waitForExistence(timeout: 5))
        }
        goBackToSubject(app)
    }

    @MainActor
    func testMergingADraftIntoAConfirmedTopicMakesTheTargetADraft() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        createTopic(app, title: "Zellatmung", confirm: true)
        let target = app.buttons["topic-Zellatmung"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.label.contains("Bestätigt"), "Label: \(target.label)")

        // Merge the seeded draft "Fotosynthese" into the confirmed topic.
        let draft = app.buttons["topic-Fotosynthese"]
        XCTAssertTrue(draft.label.contains("Entwurf"), "Label: \(draft.label)")
        draft.swipeRight()
        let merge = app.buttons["Zusammenlegen"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()
        let choice = app.buttons["choice-Zellatmung"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        // The confirmation says what happens to the status.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'wieder zum Entwurf'")).firstMatch.exists)
        app.buttons["confirmChoiceButton"].firstMatch.tap()

        let merged = app.buttons["topic-Zellatmung"]
        XCTAssertTrue(merged.waitForExistence(timeout: 5))
        XCTAssertTrue(merged.label.contains("Entwurf"), "Label: \(merged.label)")
        XCTAssertFalse(merged.label.contains("Bestätigt"), "Label: \(merged.label)")
        XCTAssertTrue(merged.label.contains("1 Eintrag"), "Label: \(merged.label)")
        XCTAssertFalse(app.buttons["topic-Fotosynthese"].exists)
    }

    @MainActor
    func testMergingAConfirmedTopicIntoAConfirmedOneAsksForReconfirmation() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        // Confirm the seeded topic.
        app.buttons["topic-Fotosynthese"].tap()
        app.buttons["confirmTopicButton"].tap()
        XCTAssertTrue(element(app, "topicConfirmedBadge").waitForExistence(timeout: 5))
        goBackToSubject(app)
        createTopic(app, title: "Zellatmung", confirm: true)

        app.buttons["topic-Fotosynthese"].swipeRight()
        app.buttons["Zusammenlegen"].tap()
        app.buttons["choice-Zellatmung"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.buttons["confirmChoiceButton"].firstMatch.tap()

        // New content in a confirmed topic: it stays confirmed but must be confirmed again.
        let merged = app.buttons["topic-Zellatmung"]
        XCTAssertTrue(merged.waitForExistence(timeout: 5))
        XCTAssertTrue(merged.label.contains("Geändert"), "Label: \(merged.label)")
        XCTAssertTrue(merged.label.contains("erneut bestätigen"), "Label: \(merged.label)")
        merged.tap()
        XCTAssertTrue(element(app, "topicModifiedHint").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirmTopicButton"].exists)
    }

    @MainActor
    func testSplittingATopicMovesTheChosenEntries() throws {
        let app = XCUIApplication()
        openSubject(app, withTopics: true)
        app.buttons["topic-Fotosynthese"].swipeRight()
        let split = app.buttons["Aufteilen"]
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.tap()
        let title = app.textFields["splitTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Chloroplast")
        let entry = app.buttons["splitEntry-0"]
        XCTAssertTrue(entry.exists)
        entry.tap()
        XCTAssertTrue(entry.isSelected)
        app.buttons["confirmSplitButton"].tap()

        // The new topic opens as a draft with the moved entry.
        XCTAssertTrue(element(app, "topicDraftBadge").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chloroplast"].waitForExistence(timeout: 5)
            || app.navigationBars["Chloroplast"].waitForExistence(timeout: 5))
        goBackToSubject(app)
        let created = app.buttons["topic-Chloroplast"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        XCTAssertTrue(created.label.contains("1 Eintrag"), "Label: \(created.label)")
        XCTAssertTrue(created.label.contains("Entwurf"), "Label: \(created.label)")
        let rest = app.buttons["topic-Fotosynthese"]
        XCTAssertTrue(rest.label.contains("0 Einträge"), "Label: \(rest.label)")
    }
}
