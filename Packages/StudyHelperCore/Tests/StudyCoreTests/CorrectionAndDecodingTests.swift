import Foundation
import Testing

@testable import StudyCore

private func rect(_ y: Double, h: Double = 0.04) -> NormalizedRect {
    NormalizedRect(x: 0.1, y: y, width: 0.8, height: h)
}

private func makeLine(_ text: String, y: Double, h: Double = 0.04, order: Int = 0) -> RecognizedLine {
    let words = text.split(separator: " ").enumerated().map { i, w in
        RecognizedWord(text: String(w), rect: NormalizedRect(x: 0.1 + 0.1 * Double(i), y: y, width: 0.09, height: h))
    }
    return RecognizedLine(text: text, rect: rect(y, h: h), words: words, order: order)
}

@Suite("Zeilen-Korrekturen zusammenführen")
struct LineCorrectionMergerTests {
    @Test("Die ursprüngliche Erkennung bleibt als recognizedText erhalten")
    func keepsRawText() {
        let line = makeLine("Zelie", y: 0.1)
        let value = LineCorrectionValue(rect: line.rect, recognizedText: "Zelie", correctedText: "Zelle")
        let outcome = CorrectionMerger.apply([value], to: [line])
        #expect(outcome.lines[0].text == "Zelle")
        #expect(outcome.lines[0].recognizedText == "Zelie")
        #expect(outcome.lines[0].isUserCorrected)
        // Applying again (restore) keeps the raw text instead of storing the correction as raw.
        let again = CorrectionMerger.apply([value], to: outcome.lines)
        #expect(again.lines[0].recognizedText == "Zelie")
        #expect(again.unmatchedIndices.isEmpty)
    }

    @Test("Zwei Korrekturen auf eng benachbarten Zeilen: eins zu eins, bester Treffer")
    func adjacentLinesOneToOne() {
        let a = makeLine("Aaa", y: 0.100), b = makeLine("Bbb", y: 0.115, order: 1)
        #expect(a.rect.iou(b.rect) > CorrectionMerger.minimumOverlap)
        let ca = LineCorrectionValue(rect: a.rect, recognizedText: "Aaa", correctedText: "A!")
        let cb = LineCorrectionValue(rect: b.rect, recognizedText: "Bbb", correctedText: "B!")
        let outcome = CorrectionMerger.apply([cb, ca], to: [makeLine("Aaa", y: 0.102), makeLine("Bbb", y: 0.117, order: 1)])
        #expect(outcome.lines.map(\.text) == ["A!", "B!"])
        #expect(outcome.unmatched.isEmpty)
    }

    @Test("Eine Zeile bekommt höchstens eine Korrektur; die andere wird als nicht zugeordnet gemeldet")
    func oneLineOneCorrection() {
        let line = makeLine("Aaa", y: 0.1)
        let c1 = LineCorrectionValue(rect: line.rect, recognizedText: "Aaa", correctedText: "eins")
        var shifted = line.rect
        shifted.y += 0.005
        let c2 = LineCorrectionValue(rect: shifted, recognizedText: "Aaa", correctedText: "zwei")
        let outcome = CorrectionMerger.apply([c1, c2], to: [line])
        #expect(outcome.unmatchedIndices.count == 1)
        #expect(outcome.lines[0].text == "eins")
    }
}

@Suite("Hervorhebungs-Korrekturen zusammenführen")
struct HighlightCorrectionMergerTests {
    private let line = makeLine("Die Zelle teilt sich", y: 0.1)

    private func automatic(_ word: Int, _ kind: HighlightKind) -> RecognizedHighlight {
        RecognizedHighlight(
            text: line.words[word].text, kind: kind, rect: line.words[word].rect, source: .goodnotesShape,
            words: [WordReference(lineID: line.id, wordIndex: word)])
    }

    @Test("Ändern, Löschen und Hinzufügen")
    func modifyDeleteAdd() {
        let underline = automatic(1, .underline), marker = automatic(3, .highlighter)
        let modify = HighlightCorrectionValue(
            action: .modify, rect: underline.rect, text: "Zelle", originalKind: .underline,
            changedFields: [.kind], kind: .circled)
        let delete = HighlightCorrectionValue(
            action: .delete, rect: marker.rect, text: "sich", originalKind: .highlighter)
        let add = HighlightCorrectionValue(
            action: .add, rect: line.words[2].rect, text: "teilt", changedFields: [.kind], kind: .bold)
        let outcome = HighlightCorrectionMerger.apply(
            [modify, delete, add], to: [underline, marker], lines: [line])
        #expect(outcome.unmatchedIndices.isEmpty)
        #expect(outcome.highlights.count == 2)
        #expect(outcome.highlights[0].kind == .circled)
        #expect(outcome.highlights[0].correctionID == modify.id)
        #expect(outcome.highlights[1].id == add.id)
        #expect(outcome.highlights[1].words == [WordReference(lineID: line.id, wordIndex: 2)])
    }

    @Test("Gleiche Ursprungsart gewinnt bei überlappenden Hervorhebungen")
    func prefersSameKind() {
        let a = automatic(1, .underline), b = automatic(1, .highlighter)
        let modify = HighlightCorrectionValue(
            action: .modify, rect: a.rect, text: "Zelle", originalKind: .highlighter,
            changedFields: [.kind], kind: .boxed)
        let outcome = HighlightCorrectionMerger.apply([modify], to: [a, b], lines: [line])
        #expect(outcome.highlights.map(\.kind) == [.underline, .boxed])
    }

    @Test("Text-Gleichheit erlaubt geringeren Überlapp; ohne Text-Gleichheit kein Treffer")
    func textAssistedMatching() {
        let h = automatic(1, .underline)
        var farRect = h.rect
        farRect.x += h.rect.width * 0.5  // IoU ≈ 0.33
        let sameText = HighlightCorrectionValue(action: .delete, rect: farRect, text: "zelle", originalKind: .underline)
        let otherText = HighlightCorrectionValue(action: .delete, rect: farRect, text: "Kern", originalKind: .underline)
        let iou = h.rect.iou(farRect)
        #expect(iou < HighlightCorrectionMerger.minimumOverlap)
        #expect(iou >= HighlightCorrectionMerger.minimumOverlapWithSameText)
        #expect(HighlightCorrectionMerger.apply([sameText], to: [h], lines: [line]).highlights.isEmpty)
        #expect(HighlightCorrectionMerger.apply([otherText], to: [h], lines: [line]).unmatchedIndices == [0])
    }

    @Test("Wiederholtes Anwenden erzeugt keine doppelten hinzugefügten Hervorhebungen")
    func addIsIdempotent() {
        let add = HighlightCorrectionValue(
            action: .add, rect: line.words[2].rect, text: "teilt", changedFields: [.kind], kind: .bold)
        let once = HighlightCorrectionMerger.apply([add], to: [], lines: [line]).highlights
        let twice = HighlightCorrectionMerger.apply([add], to: once, lines: [line]).highlights
        #expect(twice.count == 1)
    }

    @Test("Hinzugefügte Hervorhebung ohne Wörter unter dem Rect wird als nicht zugeordnet gemeldet")
    func addWithoutWords() {
        let add = HighlightCorrectionValue(
            action: .add, rect: NormalizedRect(x: 0.5, y: 0.9, width: 0.1, height: 0.02), text: "x", kind: .bold)
        #expect(HighlightCorrectionMerger.apply([add], to: [], lines: [line]).unmatchedIndices == [0])
    }
}

@Suite("Zeilen-IDs übernehmen")
struct LineIdentityTests {
    @Test("Beste Übereinstimmung, eins zu eins; Highlight-Verweise werden umgeschrieben")
    func carryOver() {
        let old = [makeLine("A", y: 0.1), makeLine("B", y: 0.2, order: 1)]
        let new = [makeLine("B", y: 0.203, order: 1), makeLine("A", y: 0.102), makeLine("C", y: 0.6, order: 2)]
        let outcome = LineIdentity.carryOver(from: old, to: new)
        #expect(outcome.lines[0].id == old[1].id)
        #expect(outcome.lines[1].id == old[0].id)
        #expect(outcome.lines[2].id == new[2].id)
        #expect(Set(outcome.lines.map(\.id)).count == 3)
        let highlight = RecognizedHighlight(
            text: "A", kind: .bold, rect: new[1].rect, source: .goodnotesShape,
            words: [WordReference(lineID: new[1].id, wordIndex: 0)])
        let remapped = LineIdentity.remap([highlight], using: outcome.idMap)
        #expect(remapped[0].words[0].lineID == old[0].id)
    }

    @Test("Zwei neue Zeilen über einer alten: nur die bessere erbt die ID")
    func oneToOne() {
        let old = [makeLine("A", y: 0.1)]
        let near = makeLine("A", y: 0.101), far = makeLine("A", y: 0.12)
        let outcome = LineIdentity.carryOver(from: old, to: [far, near])
        #expect(outcome.lines[1].id == old[0].id)
        #expect(outcome.lines[0].id != old[0].id)
    }
}

@Suite("JSON-Abwärtskompatibilität der Erkennungstypen")
struct RecognitionDecodingTests {
    @Test("Alte Blobs ohne neue Felder werden mit Standardwerten gelesen")
    func legacyJSON() throws {
        let json = """
        {"id":"7B3E4C58-6E63-4C61-9B0E-0C8E0E4D5A11","text":"Zelle","rect":{"x":0,"y":0,"width":1,"height":0.1},
         "words":[{"text":"Zelle","rect":{"x":0,"y":0,"width":1,"height":0.1}}]}
        """
        let line = try JSONDecoder().decode(RecognizedLine.self, from: Data(json.utf8))
        #expect(line.text == "Zelle")
        #expect(line.words.count == 1)
        #expect(line.status == .confident)
        #expect(line.isUserCorrected == false)
        #expect(line.recognizedText == nil)

        let highlight = try JSONDecoder().decode(
            RecognizedHighlight.self,
            from: Data(#"{"kind":"bold","rect":{"x":0,"y":0,"width":1,"height":1}}"#.utf8))
        #expect(highlight.kind == .bold)
        #expect(highlight.words.isEmpty)
        #expect(highlight.correctionID == nil)

        let meta = try JSONDecoder().decode(RecognitionMetadata.self, from: Data(#"{"method":"goodnotesInkLayers"}"#.utf8))
        #expect(meta.passes == 1)
        #expect(meta.usedReducedPDF == false)
    }

    @Test("Pflichtfelder fehlen: Dekodieren schlägt fehl statt Standardwerte zu erfinden")
    func missingIdentityFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecognizedLine.self, from: Data(#"{"words":[]}"#.utf8))
        }
    }

    @Test("Kodierung ist stabil: ungesetzte optionale Felder erscheinen nicht, Rundreise ist verlustfrei")
    func stableEncoding() throws {
        var line = makeLine("Zelle", y: 0.1)
        let data = try JSONEncoder().encode(line)
        #expect(String(data: data, encoding: .utf8)?.contains("recognizedText") == false)
        line.recognizedText = "Zelie"
        line.isUserCorrected = true
        let decoded = try JSONDecoder().decode(RecognizedLine.self, from: JSONEncoder().encode(line))
        #expect(decoded == line)
        let highlight = RecognizedHighlight(
            text: "x", kind: .circled, color: .black, rect: rect(0.1), source: .user,
            words: [WordReference(lineID: UUID(), wordIndex: 2)], correctionID: UUID())
        #expect(try JSONDecoder().decode(RecognizedHighlight.self, from: JSONEncoder().encode(highlight)) == highlight)
    }
}
