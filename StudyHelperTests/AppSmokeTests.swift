import StudyCore
import Testing
@testable import StudyHelper

@Suite("App-Grundgerüst")
@MainActor
struct AppSmokeTests {
    @Test("Startansicht lässt sich erzeugen")
    func rootViewBuilds() {
        _ = RootView().body
    }

    @Test("App ist mit dem Core-Package verknüpft")
    func coreIsLinked() {
        #expect(!StudyCore.version.isEmpty)
    }
}
