import XCTest

final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsGermanPlaceholder() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["StudyHelper"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Noch keine Fächer"].exists)
    }
}
