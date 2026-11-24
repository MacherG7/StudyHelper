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

    @Test("Commit: kurzer Hash, „*“ heißt lokale Änderungen, fehlt er, steht „unbekannt“")
    func commit() {
        #expect(AppVersion.commit(info: ["StudyHelperCommit": "ec2c94b"]) == "ec2c94b")
        #expect(AppVersion.commit(info: ["StudyHelperCommit": "ec2c94b+"]) == "ec2c94b*")
        #expect(AppVersion.hasLocalChanges(info: ["StudyHelperCommit": "ec2c94b+"]))
        #expect(!AppVersion.hasLocalChanges(info: ["StudyHelperCommit": "ec2c94b"]))
        #expect(AppVersion.commit(info: ["StudyHelperCommit": "unbekannt"]) == "unbekannt")
        #expect(AppVersion.commit(info: nil) == "unbekannt")
    }

    @Test("Die gebaute App trägt den Commit, aus dem sie gebaut wurde")
    func bundleCommit() {
        let raw = Bundle.main.infoDictionary?["StudyHelperCommit"] as? String ?? ""
        #expect(raw.wholeMatch(of: /[0-9a-f]{7}\+?/) != nil, "\(raw)")
    }
}
