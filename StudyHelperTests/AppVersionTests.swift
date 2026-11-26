import Foundation
import Testing
@testable import StudyHelper

@MainActor
@Suite("App-Version in den Einstellungen")
struct AppVersionTests {
    @Test("Anzeige: Version und Build als A.B.C.D, „(Beta)“ außer bei einer Vollversion")
    func display() {
        let final = ["StudyHelperChannel": "Final"]
        func info(_ version: String, _ build: String?, channel: String?) -> [String: Any] {
            var info: [String: Any] = ["CFBundleShortVersionString": version]
            if let build { info["CFBundleVersion"] = build }
            if let channel { info["StudyHelperChannel"] = channel }
            return info
        }
        #expect(AppVersion.display(info: info("1.0.0", "3", channel: "Beta")) == "1.0.0.3 (Beta)")
        #expect(AppVersion.display(info: info("1.0.0", "8", channel: "Final")) == "1.0.0.8")
        #expect(AppVersion.display(info: info("0.0.1", "12", channel: nil)) == "0.0.1.12 (Beta)")
        #expect(AppVersion.display(info: info("0.0.2", nil, channel: "Final")) == "0.0.2")
        #expect(AppVersion.display(info: info("0.0.2", "7", channel: "Nightly")) == "0.0.2.7 (Nightly)")
        #expect(AppVersion.display(info: final) == "unbekannt")
        #expect(AppVersion.isBeta(info: nil) && !AppVersion.isBeta(info: final))
    }

    @Test("Die App trägt die Version aus project.yml (vier Zahlen) und ist ohne --final eine Beta")
    func bundleVersion() {
        let current = AppVersion.current
        #expect(current.wholeMatch(of: /\d+\.\d+\.\d+\.\d+ \(Beta\)/) != nil, "\(current)")
        #expect(Bundle.main.infoDictionary?["StudyHelperChannel"] as? String == "Beta")
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
