import Foundation
import Testing

@testable import StudyAI

@Suite("Wortvorschläge: Umordnen der Lesarten")
struct WordRerankTests {
    private let candidates = ["Lauch", "auch", "Cauch"]

    @Test("Anfrage: feste Anweisung (nur umordnen), Kontext, nummerierte Lesarten, kein Denken")
    func request() throws {
        let request = WordSuggestions.rerankRequest(
            candidates: candidates + ["a", "b", "c", "zu viel"], before: "der mit Wasser bedeckte Teil",
            after: "alle Schnee-", subject: "Erdkunde")
        #expect(request.task == .wordSuggestions)
        #expect(request.reasoning == .off)
        #expect(request.maxOutputTokens == WordSuggestions.rerankMaxOutputTokens)
        #expect(request.system.fixed == WordSuggestions.rerankInstruction)
        #expect(request.system.editable.isEmpty)
        #expect(request.system.fixed.contains("Verwende nur die Lesarten aus der Liste"))
        #expect(request.system.fixed.contains(#"{"reihenfolge""#))
        guard case .text(let prompt) = try #require(request.messages.first?.content.first) else {
            Issue.record("Text erwartet"); return
        }
        #expect(prompt.contains("Fach: Erdkunde"))
        #expect(prompt.contains("Text davor: der mit Wasser bedeckte Teil"))
        #expect(prompt.contains("Text danach: alle Schnee-"))
        #expect(prompt.contains("1. Lauch\n2. auch\n3. Cauch"))
        #expect(prompt.contains("6. c"))
        #expect(!prompt.contains("zu viel"))

        let bare = WordSuggestions.rerankRequest(candidates: candidates, before: " ", after: "", subject: nil)
        guard case .text(let barePrompt) = try #require(bare.messages.first?.content.first) else { return }
        #expect(!barePrompt.contains("Fach:"))
        #expect(barePrompt.contains("Text davor: –"))
    }

    @Test("Auswertung: Objekt, reine Liste, Codeblock, Nummern und „2. Wort“")
    func parseFormats() {
        #expect(WordSuggestions.parseRerank(#"{"reihenfolge": ["auch", "Lauch"]}"#, candidates: candidates)
                == ["auch", "Lauch"])
        #expect(WordSuggestions.parseRerank(#"["Cauch", "auch", "Lauch"]"#, candidates: candidates)
                == ["Cauch", "auch", "Lauch"])
        let fenced = "Gern:\n```json\n{\"lesarten\": [\"auch\"]}\n```"
        #expect(WordSuggestions.parseRerank(fenced, candidates: candidates) == ["auch"])
        #expect(WordSuggestions.parseRerank(#"{"reihenfolge": [2, 1]}"#, candidates: candidates) == ["auch", "Lauch"])
        #expect(WordSuggestions.parseRerank(#"{"x": ["2. auch", "1) Lauch"]}"#, candidates: candidates)
                == ["auch", "Lauch"])
    }

    @Test("Erfundene oder veränderte Wörter fallen weg, Doppelte zählen einmal, Schreibweise der Kandidaten")
    func onlyGivenCandidates() {
        #expect(WordSuggestions.parseRerank(#"["Bauch", "AUCH", "auch", "Rauch", "lauch"]"#, candidates: candidates)
                == ["auch", "Lauch"])
        #expect(WordSuggestions.parseRerank(#"[7, 0, -1, "7"]"#, candidates: candidates).isEmpty)
    }

    @Test("Fehlerhafte Antworten ergeben eine leere Liste")
    func malformed() {
        for text in ["", "auch", #"{"reihenfolge": ["auch""#, #"{"reihenfolge": "auch"}"#, "42", "{,}"] {
            #expect(WordSuggestions.parseRerank(text, candidates: candidates).isEmpty)
        }
    }

    @Test("Mit dem Mock-Anbieter: Anfrage geht raus, Antwort wird ausgewertet")
    func withMock() async throws {
        let provider = MockProvider(script: MockScript(answer: #"{"reihenfolge": ["auch", "Bauch", "Lauch"]}"#))
        let order = try await WordSuggestions.rerank(
            candidates: candidates, before: "Teil der Erdoberfläche", after: "alle", subject: nil, provider: provider)
        #expect(order == ["auch", "Lauch"])
        #expect(provider.receivedRequests.count == 1)
        #expect(provider.receivedRequests[0].system.fixed == WordSuggestions.rerankInstruction)
    }
}
