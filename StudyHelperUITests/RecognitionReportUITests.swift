import XCTest

/// Entwickler-Modus: Liste der Erkennungsfehler (Kopieren, Teilen, Alles löschen) mit einem Demo-Eintrag
/// (`-uiTestSeedReports`). Das Melden selbst läuft in der Prüfansicht und wird dort getestet.
final class RecognitionReportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) fehlt")
        XCTAssertTrue(element.isHittable, "\(element) nicht erreichbar")
    }

    /// Review screen: with the developer mode on, a selected line offers "Fehler melden"; the saved report shows up in
    /// "Einstellungen → Erkennungsfehler". Without the developer mode there is no such button.
    @MainActor
    func testReportALineFromTheReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemory", "-uiTestMockAI", "-uiTestSeed"]
        app.launch()

        func openReview() {
            let subject = app.buttons["subject-Biologie"]
            XCTAssertTrue(subject.waitForExistence(timeout: 10))
            subject.tap()
            let row = app.buttons["importRow"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let picker = app.segmentedControls["modePicker"]
            if picker.waitForExistence(timeout: 10) { picker.buttons["Text"].tap() }
            let line = app.buttons["reviewLine-1"]
            XCTAssertTrue(line.waitForExistence(timeout: 5))
            line.tap()
            XCTAssertTrue(app.buttons["correctLineButton"].waitForExistence(timeout: 5))
        }

        // Developer mode off: no report button.
        openReview()
        XCTAssertFalse(app.buttons["reportErrorButton"].exists)
        XCTAssertFalse(app.buttons["reportAreaButton"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        // Turn the developer mode on in the settings.
        app.buttons["settingsButton"].tap()
        let developer = app.switches["developerModeToggle"]
        reveal(developer, in: app)
        developer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["Fertig"].tap()

        openReview()
        XCTAssertTrue(app.buttons["reportAreaButton"].exists)
        let report = app.buttons["reportErrorButton"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        XCTAssertEqual(app.staticTexts["reportPlaceText"].label, "Ort: Chloroplasten")
        let save = app.buttons["reportSaveButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["correctLineButton"].waitForExistence(timeout: 5))

        // The entry is in the settings list.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settingsButton"].tap()
        let link = app.buttons["recognitionReportsLink"]
        reveal(link, in: app)
        XCTAssertTrue(link.label.contains("(1)"), "die Zahl der Einträge steht im Link: \(link.label)")
        link.tap()
        XCTAssertTrue(app.buttons["reportEntryRow"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testReportListCopyAndDeleteAll() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemory", "-uiTestMockAI", "-uiTestSeedReports"]
        app.launch()
        app.buttons["settingsButton"].tap()

        // Ohne Developer-Modus gibt es keinen Zugang.
        let developer = app.switches["developerModeToggle"]
        reveal(developer, in: app)
        XCTAssertFalse(app.buttons["recognitionReportsLink"].exists)
        developer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        let link = app.buttons["recognitionReportsLink"]
        reveal(link, in: app)
        XCTAssertTrue(link.label.contains("(1)"), "die Zahl der Einträge steht im Link: \(link.label)")
        link.tap()

        let row = app.buttons["reportEntryRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let corrections = app.switches["includeCorrectionsToggle"]
        XCTAssertTrue(corrections.exists)
        XCTAssertEqual(corrections.value as? String, "0", "Korrekturen werden nur auf Wunsch mitgeschickt")
        XCTAssertTrue(app.buttons["shareReportButton"].exists)

        let copy = app.buttons["copyReportButton"]
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        XCTAssertTrue(app.staticTexts["Kopiert"].waitForExistence(timeout: 3))

        // Alles löschen: erst die Rückfrage, nach der Bestätigung ist die Liste leer.
        let deleteAll = app.buttons["deleteAllReportsButton"]
        XCTAssertTrue(deleteAll.isEnabled)
        deleteAll.tap()
        let confirm = app.buttons["confirmDeleteAllReportsButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["noReportsText"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertFalse(deleteAll.isEnabled)
    }
}
