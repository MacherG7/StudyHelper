import CoreGraphics
import Foundation
import StudyCore
import Testing
@testable import StudyImport

@Suite("Schriftprüfung: fremde Schriften in deutscher Handschrift")
struct ScriptGuardTests {
    @Test("Deutsche Texte mit Umlauten, ß, Ziffern, Satzzeichen und Symbolen sind plausibel", arguments: [
        "Lithosphäre", "Größe und Maße", "Übergangsraum von der Wüste", "Fe₂O₃ → H₂O", "5 + 3 = 8", "z.B. (Tiere, Pilze)",
        "Café Résumé naïve", "– gasförmige Hülle", "100 % • ½ Liter", "ﬁnden ﬂiegen", "",
    ])
    func plausible(text: String) {
        #expect(ScriptGuard.isPlausible(text), "\(text)")
    }

    @Test("Kyrillisch, griechisch, arabisch, chinesisch und türkische Buchstaben sind unplausibel", arguments: [
        "Міста", "ІŞ Міста", "Привет", "Γεια σου", "مرحبا", "你好", "こんにちは", "한국어", "İstanbul", "ısı", "Şule", "Ağaç",
        "Niger Міста", "Tschad Δ",
    ])
    func implausible(text: String) {
        #expect(!ScriptGuard.isPlausible(text), "\(text)")
    }

    private func line(_ text: String, candidates: [String] = [], confidence: Double = 0.4) -> RecognizedLine {
        var line = mockLine(text, x: 0.1, y: 0.2, wordWidth: 0.1)
        line.confidence = confidence
        line.candidates = candidates
        return line
    }

    @Test("Eine unplausible Zeile wird durch die erste plausible Alternative ersetzt, Wortboxen liegen in der Zeile")
    func firstPlausibleCandidateWins() {
        let original = line("Міста", candidates: ["Мiста", "Mista", "Nista"])
        let result = ScriptGuard.apply(to: original)
        #expect(result.text == "Mista")
        #expect(result.candidates.first == "Міста", "der verworfene Text bleibt als Alternative erhalten")
        #expect(result.words.map(\.text) == ["Mista"])
        #expect(result.rect == original.rect)
        #expect(result.words.allSatisfy { $0.rect.coverage(by: original.rect.insetBy(dx: -1e-9, dy: -1e-9)) > 0.99 })
        #expect(result.id == original.id)
    }

    @Test("Ohne plausible Alternative bleibt der Text, die Zeile ist unsicher mit Grund lowConfidence")
    func noCandidateMarksUncertain() {
        let result = ScriptGuard.apply(to: line("ІŞ Міста", candidates: ["Міста", "Şista"], confidence: 0.9))
        #expect(result.text == "ІŞ Міста")
        #expect(result.status == .uncertain)
        #expect(result.reviewReasons.contains(.lowConfidence))
        #expect(result.words.allSatisfy { $0.status == .uncertain && $0.reviewReasons.contains(.lowConfidence) })
    }

    @Test("Nur die Wörter mit fremden Buchstaben werden als unsicher markiert; unleserlich bleibt unleserlich")
    func onlyForeignWordsAreFlagged() {
        var mixed = line("Niger Міста Tschad")
        mixed.status = .illegible
        let result = ScriptGuard.apply(to: mixed)
        #expect(result.status == .illegible, "nie besser als zuvor")
        #expect(result.words.map(\.status) == [.confident, .uncertain, .confident])
    }

    @Test("Plausible und vom Nutzer korrigierte Zeilen bleiben unverändert")
    func untouched() {
        let fine = line("Lithosphäre ist fest", confidence: 0.9)
        #expect(ScriptGuard.apply(to: fine) == fine)
        var corrected = line("Міста")
        corrected.isUserCorrected = true
        #expect(ScriptGuard.apply(to: corrected) == corrected)
    }

    @Test("Foto: eine kyrillisch gelesene Zeile wird durch die plausible Alternative ersetzt (alle Erkennungswege)")
    func photoUsesGuard() async throws {
        let recognizer = CountingRecognizer { _, _, _ in
            mockOutput(self.line("Міста", candidates: ["Nista", "Mista"], confidence: 0.6), mockLine("Normal", y: 0.5))
        }
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment)
        let result = try await pipeline.digitizeImage(blankImage()).result
        #expect(result.lines.map(\.text) == ["Nista", "Normal"])
        #expect(result.originalMarkdown.contains("Nista") && !result.originalMarkdown.contains("М"))
    }
}
