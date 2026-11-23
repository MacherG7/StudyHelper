import XCTest

final class LaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsGermanPlaceholder() throws {
        let app = XCUIApplication()
        // In-memory store: the test must not depend on subjects left in the simulator's real store.
        app.launchArguments = ["-uiTestInMemory"]
        app.launch()

        XCTAssertTrue(app.navigationBars["StudyHelper"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Noch keine Fächer"].waitForExistence(timeout: 5))
    }
}
