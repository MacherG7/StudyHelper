import Foundation
import Testing
@testable import StudyHelper

@MainActor
@Suite("App-Version in den Einstellungen")
struct AppVersionTests {
    @Test("Anzeige: Version und Build als A.B.C.D")
    func display() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "0"]) == "0.0.1.0")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "12"]) == "0.0.1.12")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.0.2"]) == "0.0.2")
        #expect(AppVersion.display(info: nil) == "unbekannt")
    }

    @Test("Die App trägt die Version aus project.yml (vier Zahlen, nicht mehr fest 1.0)")
    func bundleVersion() {
        let current = AppVersion.current
        #expect(current.wholeMatch(of: /\d+\.\d+\.\d+\.\d+/) != nil, "\(current)")
        #expect(!current.hasPrefix("1.0"))
    }
}
