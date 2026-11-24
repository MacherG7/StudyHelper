import CoreGraphics
import Foundation
import StudyCore
import Testing
@testable import StudyImport

/// Rules found while tuning on a real Goodnotes export (docs/DECISIONS.md D-022).
@Suite("Erkennungsregeln aus dem Abgleich mit echten Notizen")
struct RecognitionHeuristicsTests {
    @Test("„z.B.“ mit ß statt B wird korrigiert, die alte Lesung bleibt als Alternative; echte ß bleiben")
    func zumBeispiel() {
        #expect(KnownMisreadings.fix("auf Erde (z.ß, Siedlungen") == "auf Erde (z.B, Siedlungen")
        #expect(KnownMisreadings.fix("Großprojekte (2.ß. Staudammbau);") == "Großprojekte (z.B. Staudammbau);")
        #expect(KnownMisreadings.fix("z. ß. Wasser") == "z.B. Wasser")
        for kept in ["Fuß.", "Maß, Gruß", "Straße", "groß.", "Spaß"] { #expect(KnownMisreadings.fix(kept) == kept) }
        let line = RecognizedLine(
            text: "(z.ß, Felder", rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.05),
            words: [RecognizedWord(text: "(z.ß,", rect: .zero), RecognizedWord(text: "Felder", rect: .zero)])
        let fixed = KnownMisreadings.apply(to: line)
        #expect(fixed.text == "(z.B, Felder" && fixed.words.map(\.text) == ["(z.B,", "Felder"])
        #expect(fixed.candidates.first == "(z.ß, Felder")
    }

    @Test("Schriftprüfung: Buchstaben jenseits von Latin-1 (ą ę ś ạ ị) sind verdächtig, Œ Š Ž ẞ und Akzente nicht")
    func latinExtended() {
        for bad in ["Pedosphäręąś", "Grüne Maneriại", "Łódź", "İstanbul"] { #expect(!ScriptGuard.isPlausible(bad), "\(bad)") }
        for good in ["Straße", "Café crème", "Œuvre", "Šibenik", "GROẞ", "Ålesund", "naïve", "Ø 3 cm"] {
            #expect(ScriptGuard.isPlausible(good), "\(good)")
        }
    }

    @Test("Buchstabenabstand ignoriert Groß-/Kleinschreibung, Leerzeichen und Satzzeichen")
    func letterDistance() {
        #expect(HandwritingRetry.letterDistance("„Zai-Methode\"", "„Zai-Methodei") == 1)
        #expect(HandwritingRetry.letterDistance("GlobaL Footprint", "Global  Footprint") == 0)
        #expect(HandwritingRetry.letterDistance("ikhdrom: beschreibung", "„Syndrom\": beschreibung") >= 3)
        #expect(HandwritingRetry.letterDistance("", "abc") == 3)
    }

    @Test("Unterstrichene Zeile behält ihre Lesung, wenn der Ausschnitt dasselbe (±1 Buchstabe) oder nichts liest")
    func keepsOriginal() {
        let line = RecognizedLine(text: "Der Earth Overshoot Day", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.04))
        func reading(_ text: String, y: Double = 0.105) -> RecognizedLine {
            RecognizedLine(text: text, rect: NormalizedRect(x: 0.12, y: y, width: 0.55, height: 0.03))
        }
        #expect(HandwritingRetry.keepsOriginal(line, readings: []))
        #expect(HandwritingRetry.keepsOriginal(line, readings: [reading("Der Earth Overshoot Dayl")]))
        #expect(!HandwritingRetry.keepsOriginal(line, readings: [reading("Der „Earth Overshoot Day\" ist")]))
        #expect(HandwritingRetry.keepsOriginal(line, readings: [reading("ganz anderer Text", y: 0.5)]), "Lesungen außerhalb zählen nicht")
    }

    @Test("Eine Zeile gilt als unterstrichen bei einem langen flachen Strich in ihrer unteren Hälfte oder knapp darunter")
    func underlinedGeometry() {
        let size = PageSize(width: 600, height: 800)
        let line = RecognizedLine(text: "Syndrom", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03))  // 80…104 pt
        let lh = 20.0
        let below = CGRect(x: 60, y: 106, width: 150, height: 2)
        let farBelow = CGRect(x: 60, y: 120, width: 150, height: 2)
        let above = CGRect(x: 60, y: 82, width: 150, height: 2)
        let aside = CGRect(x: 400, y: 100, width: 150, height: 2)
        #expect(HandwritingRetry.isUnderlined(line, underlines: [below], pageSize: size, lineHeight: lh))
        #expect(!HandwritingRetry.isUnderlined(line, underlines: [farBelow, above, aside], pageSize: size, lineHeight: lh))
        var corrected = line
        corrected.isUserCorrected = true
        #expect(!HandwritingRetry.isUnderlined(corrected, underlines: [below], pageSize: size, lineHeight: lh))
    }

    @Test("Zwei eng gestapelte Zeilen ohne tiefes Tal werden im Notfall an der dünnsten Stelle getrennt")
    func forcedRows() {
        let lh = 20.0
        // Row 1 at 100…118, row 2 at 120…138; three long descenders (g, j, y) fill the gap between the rows, so
        // the ink profile has only a shallow valley there.
        var boxes: [CGRect] = []
        for i in 0..<5 { boxes.append(CGRect(x: Double(i) * 12, y: 100, width: 10, height: 18)) }
        for i in 0..<5 { boxes.append(CGRect(x: Double(i) * 12, y: 120, width: 10, height: 18)) }
        for i in 0..<3 { boxes.append(CGRect(x: 70 + Double(i) * 12, y: 100, width: 10, height: 38)) }
        #expect(InkRows.rows(of: boxes, lineHeight: lh).count == 1, "ohne Notfall eine Zeile")
        let rows = InkRows.forcedRows(of: Array(boxes.indices), boxes: boxes, lineHeight: lh)
        #expect(rows.count == 2)
        if rows.count == 2 {
            #expect(Set(0..<5).isSubset(of: Set(rows[0])) && Set(5..<10).isSubset(of: Set(rows[1])))
        }
        #expect(InkRows.forcedRows(of: Array(0..<5), boxes: boxes, lineHeight: lh).count == 1, "eine einzelne Zeile bleibt ganz")
    }

    @Test("Vertikaler Anteil: ein Wort der Zeile darüber wird nicht von der Zeile darunter erklärt")
    func verticalShare() {
        let line = CGRect(x: 0, y: 100, width: 300, height: 20)
        #expect(IllegibleInk.verticalShare(of: CGRect(x: 10, y: 92, width: 10, height: 10), in: line) == 0.2)
        #expect(IllegibleInk.verticalShare(of: CGRect(x: 10, y: 105, width: 10, height: 10), in: line) == 1)
        #expect(IllegibleInk.verticalShare(of: CGRect(x: 10, y: 110, width: 10, height: 0.2), in: line) == 1, "flacher Strich: Mitte zählt")
    }

    @Test("Nachlesen: ein Strich, den zwei Zeilen beanspruchen, gehört zur näheren Zeile; hohe Ausschnitte behalten alles")
    func exclusiveStrokes() {
        let strokes = [
            IllegibleInk.Candidate(index: 1, box: CGRect(x: 0, y: 70, width: 10, height: 10)),
            IllegibleInk.Candidate(index: 2, box: CGRect(x: 20, y: 78, width: 6, height: 14)),  // descender, center 85
            IllegibleInk.Candidate(index: 3, box: CGRect(x: 0, y: 95, width: 10, height: 10)),
        ]
        let upper = HandwritingRetry.Segment(layer: 0, strokes: [1, 2], box: .zero, rowMid: 80)
        let lower = HandwritingRetry.Segment(layer: 0, strokes: [2, 3], box: .zero, rowMid: 100)
        let result = HandwritingRetry.exclusive([upper, lower], strokes: strokes)
        #expect(result.map(\.strokes) == [[1, 2], [3]])
        #expect(result[1].box == CGRect(x: 0, y: 95, width: 10, height: 10))

        var tall = lower
        tall.isSingleRow = false
        #expect(HandwritingRetry.exclusive([upper, tall], strokes: strokes).map(\.strokes) == [[1, 2], [2, 3]])
    }
}
