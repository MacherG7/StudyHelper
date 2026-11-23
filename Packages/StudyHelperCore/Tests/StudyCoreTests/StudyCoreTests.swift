import Testing
@testable import StudyCore

@Suite("StudyCore")
struct StudyCoreTests {
    @Test("Version ist gesetzt und hat das Format x.y.z")
    func versionFormat() {
        let parts = StudyCore.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
