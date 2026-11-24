import Foundation
import Testing

@testable import StudyCore

private struct Card: Codable, Equatable {
    var front: String
    var back: String
}

private struct Deck: Codable, Equatable {
    var cards: [Card]
}

@Suite("Strukturierte Ausgabe")
struct StructuredOutputTests {
    private let valid = #"{"cards":[{"front":"A \"quoted\" } {","back":"B"},{"front":"C","back":"D\\"}]}"#

    @Test("Reines JSON wird gelesen")
    func plain() throws {
        let deck = try StructuredOutput.decode(Deck.self, from: valid).get()
        #expect(deck.cards.count == 2)
        #expect(deck.cards[0].front == #"A "quoted" } {"#)
    }

    @Test("Code-Zaun mit json wird entfernt")
    func fenced() throws {
        let text = "```json\n\(valid)\n```"
        #expect(try StructuredOutput.decode(Deck.self, from: text).get().cards.count == 2)
    }

    @Test("Text vor und nach dem JSON wird ignoriert")
    func prose() throws {
        let text = "Hier ist das Ergebnis: \(valid)\nViel Erfolg [sic]!"
        #expect(try StructuredOutput.decode(Deck.self, from: text).get().cards.count == 2)
    }

    @Test("Array an oberster Stelle")
    func array() throws {
        let cards = try StructuredOutput.decode([Card].self, from: #"Liste: [{"front":"a","back":"b"}] Ende"#).get()
        #expect(cards == [Card(front: "a", back: "b")])
    }

    @Test("Kein JSON im Text")
    func noJSON() {
        #expect(StructuredOutput.decode(Deck.self, from: "Nur Text.") == .failure(.noJSON))
        #expect(StructuredOutput.decode(Deck.self, from: "") == .failure(.noJSON))
    }

    @Test("Abgeschnittenes JSON wird als abgeschnitten erkannt")
    func truncated() {
        let cut = String(valid.prefix(valid.count - 5))
        #expect(StructuredOutput.decode(Deck.self, from: cut) == .failure(.truncated))
        #expect(StructuredOutputError.truncated.message.contains("abgeschnitten"))
    }

    @Test("Ungültiges JSON und falscher Typ werden unterschieden")
    func invalidAndMismatch() {
        if case .failure(.invalidJSON) = StructuredOutput.decode(Deck.self, from: #"{"cards": [1,,2]}"#) {} else {
            Issue.record("invalidJSON erwartet")
        }
        if case .failure(.invalidJSON) = StructuredOutput.decode(Deck.self, from: "{ ] }") {} else {
            Issue.record("invalidJSON erwartet")
        }
        if case .failure(.typeMismatch(let detail)) = StructuredOutput.decode(Deck.self, from: #"{"cards":[{"front":"a"}]}"#) {
            #expect(detail.contains("back"))
        } else {
            Issue.record("typeMismatch erwartet")
        }
        if case .failure(.typeMismatch) = StructuredOutput.decode(Deck.self, from: #"{"other":1}"#) {} else {
            Issue.record("typeMismatch erwartet")
        }
    }

    @Test("Zufällige Abschnitte, Präfixe und Müll führen nie zum Absturz")
    func fuzz() {
        var generator = SystemRandomNumberGenerator()
        let scalars = Array(valid)
        for cut in 0...scalars.count {
            _ = StructuredOutput.decode(Deck.self, from: String(scalars.prefix(cut)))
            _ = StructuredOutput.decode(Deck.self, from: String(scalars.suffix(cut)))
        }
        let alphabet = Array("{}[]\"\\:, abc\n`")
        for _ in 0..<500 {
            let length = Int.random(in: 0..<60, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            _ = StructuredOutput.decode(Deck.self, from: text)
        }
        var cutResult = 0
        for cut in 0..<scalars.count {
            if case .success = StructuredOutput.decode(Deck.self, from: String(scalars.prefix(cut))) { cutResult += 1 }
        }
        #expect(cutResult == 0)
    }
}
