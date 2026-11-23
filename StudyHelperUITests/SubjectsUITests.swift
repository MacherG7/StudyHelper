import XCTest

final class SubjectsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateSubjectAppearsInList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemory"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Noch keine Fächer"].waitForExistence(timeout: 10))
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
