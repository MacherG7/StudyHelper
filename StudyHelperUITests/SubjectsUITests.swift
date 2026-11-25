import XCTest

/// Start (German placeholder) and creating a subject in one launch; the former separate launch test is covered by the
/// first two assertions.
final class SubjectsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateSubjectAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemory"]
        app.launch()

        XCTAssertTrue(app.navigationBars["StudyHelper"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Noch keine Fächer"].waitForExistence(timeout: 5))
        app.buttons["addSubjectButton"].tap()

        let field = app.textFields["subjectNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Geschichte")
        app.buttons["saveSubjectButton"].tap()

        XCTAssertTrue(app.staticTexts["Geschichte"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Noch keine Fächer"].exists)
    }
}
