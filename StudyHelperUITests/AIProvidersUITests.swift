import XCTest

/// KI-Anbieter, Verbindungstest, Developer-Modus und Anfrage-Log mit dem Mock-Anbieter (kein Netz, keine Keychain).
/// Mit `TEST_RUNNER_UI_SCREENSHOT_DIR=<Ordner>` speichert der Test Bildschirmfotos dorthin.
final class AIProvidersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemory", "-uiTestMockAI"]
        app.launch()
        return app
    }

    /// Scrolls until the element can be tapped.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) fehlt", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(element) nicht erreichbar", file: file, line: line)
    }

    private func snapshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["UI_SCREENSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func choose(_ option: String, from picker: XCUIElement, in app: XCUIApplication) {
        picker.tap()
        let button = app.buttons[option]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Auswahl „\(option)“ fehlt")
        button.tap()
    }

    @MainActor
    func testAddProviderTestConnectionAndRequestLog() throws {
        let app = launch()
        app.buttons["settingsButton"].tap()

        // Anbieter hinzufügen.
        reveal(app.buttons["addProviderButton"], in: app)
        snapshot("1-einstellungen")
        app.buttons["addProviderButton"].tap()

        let key = app.secureTextFields["providerKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveProviderButton"].isEnabled, "Ohne Key und Modell nicht speicherbar")
        key.tap()
        key.typeText("testschluessel-123456")

        app.buttons["fetchModelsButton"].tap()
        let modelPicker = app.buttons["modelPicker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 10))

        // Modell mit Denktiefe: nur die Stufen des Modells.
        choose("Mock denkend", from: modelPicker, in: app)
        let reasoning = app.buttons["reasoningPicker"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
        reasoning.tap()
        for level in ["Aus", "Niedrig", "Mittel", "Hoch"] {
            XCTAssertTrue(app.buttons[level].waitForExistence(timeout: 5), "Stufe \(level) fehlt")
        }
        for level in ["Minimal", "Sehr hoch", "Maximal"] {
            XCTAssertFalse(app.buttons[level].exists, "Stufe \(level) darf nicht angeboten werden")
        }
        snapshot("2-anbieter-denktiefe")
        app.buttons["Niedrig"].tap()

        // Modell ohne Denktiefe: Auswahl verschwindet.
        choose("Mock schnell", from: app.buttons["modelPicker"], in: app)
        XCTAssertTrue(waitForDisappearance(of: app.buttons["reasoningPicker"]))

        // Wieder das denkende Modell, dann Verbindung testen.
        choose("Mock denkend", from: app.buttons["modelPicker"], in: app)
        reveal(app.buttons["testConnectionButton"], in: app)
        app.buttons["testConnectionButton"].tap()
        let result = app.staticTexts["Verbindung OK"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        snapshot("3-verbindungstest")

        // Sichern: der Anbieter steht in der Liste.
        app.buttons["saveProviderButton"].tap()
        XCTAssertTrue(app.buttons["providerRow-Claude"].waitForExistence(timeout: 5))

        // Developer-Modus einschalten, Log öffnen.
        let developer = app.switches["developerModeToggle"]
        reveal(developer, in: app)
        developer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        reveal(app.buttons["requestLogLink"], in: app)
        app.buttons["requestLogLink"].tap()

        let row = app.buttons["requestLogRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Verbindungstest"), "Eintrag des Verbindungstests erwartet: \(row.label)")
        snapshot("4-anfrage-log")
        row.tap()
        XCTAssertTrue(app.navigationBars["Anfrage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["disclosure-prompt"].exists || app.staticTexts["Tokens"].exists || app.staticTexts["TOKENS"].exists)
        snapshot("5-log-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Logs löschen.
        app.buttons["logMenu"].tap()
        app.buttons["deleteLogsButton"].tap()
        app.buttons["confirmDeleteLogsButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Noch keine Anfragen"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeveloperModeHidesLogUntilEnabled() throws {
        let app = launch()
        app.buttons["settingsButton"].tap()
        let developer = app.switches["developerModeToggle"]
        reveal(developer, in: app)
        XCTAssertFalse(app.buttons["requestLogLink"].exists)
        developer.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["requestLogLink"].waitForExistence(timeout: 5))
        reveal(app.buttons["priceTableLink"], in: app)
    }

    @MainActor
    func testTasksAndPriceTable() throws {
        let app = launch()
        app.buttons["settingsButton"].tap()
        reveal(app.buttons["reasoningOverride-query"], in: app)
        choose("Hoch", from: app.buttons["reasoningOverride-query"], in: app)
        reveal(app.buttons["priceTableLink"], in: app)
        app.buttons["priceTableLink"].tap()
        XCTAssertTrue(app.buttons["priceRow-claude-sonnet-5-5"].waitForExistence(timeout: 5))
        snapshot("6-preistabelle")
        reveal(app.buttons["addPriceButton"], in: app)
        app.buttons["addPriceButton"].tap()
        let model = app.textFields["priceModelField"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        model.typeText("mein-modell")
        app.textFields["priceInputField"].tap()
        app.textFields["priceInputField"].typeText("1,5")
        app.textFields["priceOutputField"].tap()
        app.textFields["priceOutputField"].typeText("7")
        app.buttons["savePriceButton"].tap()
        XCTAssertTrue(app.buttons["priceRow-mein-modell"].waitForExistence(timeout: 5))
        // Eigener Preis ist als angepasst markiert; zurücksetzen entfernt ihn wieder.
        reveal(app.buttons["resetPricesButton"], in: app)
        app.buttons["resetPricesButton"].tap()
        XCTAssertTrue(waitForDisappearance(of: app.buttons["priceRow-mein-modell"]))
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
