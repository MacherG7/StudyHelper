import Foundation
import Testing

@testable import StudyAI

@Suite("Wortvorschläge")
struct WordSuggestionsTests {
    @Test("Anfrage: feste Anweisung mit Grundregel, Kontext, kein Denken, kurze Ausgabe")
    func request() throws {
        let request = WordSuggestions.request(
            word: "Eingrifte", before: "Durch die", after: "des Menschen in das", subject: "Erdkunde")
        #expect(request.task == .wordSuggestions)
        #expect(request.reasoning == .off)
        #expect(request.maxOutputTokens == WordSuggestions.maxOutputTokens)
        #expect(request.system.fixed == WordSuggestions.instruction)
        #expect(request.system.editable.isEmpty)
        #expect(request.tools.isEmpty && request.responseSchema == nil)
        #expect(request.system.fixed.contains("Keine neuen Inhalte"))
        #expect(request.system.fixed.contains(#"{"vorschlaege""#))
        guard case .text(let prompt) = try #require(request.messages.first?.content.first) else {
            Issue.record("Text erwartet"); return
        }
        #expect(prompt.contains("Fach: Erdkunde"))
        #expect(prompt.contains("Text davor: Durch die"))
        #expect(prompt.contains("Unsicheres Wort: Eingrifte"))
        #expect(prompt.contains("Text danach: des Menschen in das"))
        #expect(request.sentContent == [.text])

        let bare = WordSuggestions.request(word: "Klimg", before: "", after: " ", subject: nil)
        guard case .text(let barePrompt) = try #require(bare.messages.first?.content.first) else { return }
        #expect(!barePrompt.contains("Fach:"))
        #expect(barePrompt.contains("Text davor: –"))
    }

    @Test("Auswertung: JSON-Objekt, Codeblock, Prosa und reines Array")
    func parseFormats() {
        #expect(WordSuggestions.parse(#"{"vorschlaege": ["Eingriffe", "Eingriffen"]}"#, original: "Eingrifte")
                == ["Eingriffe", "Eingriffen"])
        let fenced = "Hier sind Vorschläge:\n```json\n{\"vorschläge\": [\"Klima\"]}\n```\nViel Erfolg!"
        #expect(WordSuggestions.parse(fenced, original: "Klimg") == ["Klima"])
        #expect(WordSuggestions.parse(#"["passt", "fasst"]"#, original: "tasst") == ["passt", "fasst"])
    }

    @Test("Auswertung filtert: ein Wort, ähnliche Länge, Buchstaben, ohne Duplikate und Original, höchstens 5")
    func parseFilters() {
        let answer = #"""
        {"vorschlaege": ["Eingriffe.", "eingriffe", "Eingrifte", "die Eingriffe", "Ein", "Eingriffeeeeeeeeee",
         "E1n9r1ff3", "Ein-griff-e", "Eingriff", "Eingriffen", "Eingriffes", "Eingriffs", "Eingreife", 42, null]}
        """#
        #expect(WordSuggestions.parse(answer, original: "Eingrifte")
                == ["Eingriffe", "Eingriff", "Eingriffen", "Eingriffes", "Eingriffs"])
        // One hyphen or apostrophe is fine; two words only if the original had two.
        #expect(WordSuggestions.parse(#"["Erd-Kruste", "geht's", "Erd-Kru-ste"]"#, original: "Erdkruste") == ["Erd-Kruste", "geht's"])
        #expect(WordSuggestions.parse(#"["zu dem", "zum"]"#, original: "zu dem") == ["zum"])
        #expect(WordSuggestions.parse(#"["zu dem", "zudem"]"#, original: "zu den") == ["zu dem", "zudem"])
        // Lower case variant of the original is kept (capitalization fix).
        #expect(WordSuggestions.parse(#"["Umwelt"]"#, original: "umwelt") == ["Umwelt"])
    }

    @Test("Fehlerhafte Antworten ergeben eine leere Liste")
    func malformed() {
        for text in ["", "Keine Ahnung.", #"{"vorschlaege": ["Klima""#, #"{"andere": ["Klima"]}"#, "{\"vorschlaege\": \"Klima\"}",
                     "42", "[[\"Klima\"]]", "{,}"] {
            #expect(WordSuggestions.parse(text, original: "Klimg").isEmpty)
        }
    }

    @Test("Mit dem Mock-Anbieter: Anfrage geht raus, Antwort wird ausgewertet")
    func withMock() async throws {
        let provider = MockProvider(script: MockScript(answer: #"{"vorschlaege": ["Klima", "Kling", "Klimg"]}"#))
        let suggestions = try await WordSuggestions.suggest(
            word: "Klimg", before: "Prozesse → für", after: "verantwortlich", subject: "Erdkunde", provider: provider)
        #expect(suggestions == ["Klima", "Kling"])
        #expect(provider.receivedRequests.count == 1)
        #expect(provider.receivedRequests[0].task == .wordSuggestions)

        provider.script = MockScript(error: .unavailable("Apple Intelligence ist aus."))
        await #expect(throws: (any Error).self) {
            _ = try await WordSuggestions.suggest(word: "Klimg", before: "", after: "", subject: nil, provider: provider)
        }
    }
}
