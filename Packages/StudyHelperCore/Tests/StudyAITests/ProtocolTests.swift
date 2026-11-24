import Testing
@testable import StudyAI

@Suite("Protokoll")
struct ProtocolTests {
    @Test("Systemprompt: fester Teil immer zuerst, leere Teile entfallen")
    func promptParts() {
        #expect(PromptParts(fixed: "Regel", editable: "Text").combined == "Regel\n\nText")
        #expect(PromptParts(fixed: "Regel").combined == "Regel")
    }
}
