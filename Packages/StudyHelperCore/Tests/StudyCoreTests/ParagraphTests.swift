import Foundation
import StudyCore
import Testing

/// Lines that belong together are stored as paragraphs (joined text with position).
@Suite("Absätze aus zusammenhängenden Zeilen")
struct ParagraphTests {
    let black = RGBColor(hex: "#1E1B1B")
    let green = RGBColor(hex: "#00FF00")

    /// A handwritten line: rows 0.03 apart, 0.025 high (dense handwriting, boxes nearly touching).
    func line(_ text: String, row: Double, x: Double = 0.06, width: Double = 0.85, order: Int,
              color: RGBColor? = RGBColor(hex: "#1E1B1B"), height: Double = 0.025,
              status: ConfidenceStatus = .confident) -> RecognizedLine {
        RecognizedLine(
            text: text, rect: NormalizedRect(x: x, y: 0.1 + row * 0.03, width: width, height: height),
            status: status, color: color, order: order)
    }

    func paragraphs(_ lines: [RecognizedLine]) -> [String] {
        ParagraphGrouping.paragraphs(of: ParagraphGrouping.assign(lines)).map(\.text)
    }

    @Test("Prosa über drei Zeilen wird ein Absatz; Trennstrich am Zeilenende wird aufgelöst, Ergänzungsstrich bleibt")
    func prose() {
        let texts = paragraphs([
            line("Eine Landschaft setzt sich aus verschiedenen Teil-", row: 0, order: 0),
            line("bereichen zusammen, den Geosphären. Wasser, Schnee-", row: 1, order: 1),
            line("und Eisflächen gehören dazu.", row: 2, width: 0.4, order: 2),
        ])
        #expect(texts == ["Eine Landschaft setzt sich aus verschiedenen Teilbereichen zusammen, den Geosphären. Wasser, Schnee- und Eisflächen gehören dazu."])
    }

    @Test("Absatz enthält Position (Vereinigung der Zeilen) und die Zeilen in Lesereihenfolge")
    func positionAndLines() throws {
        let lines = ParagraphGrouping.assign([
            line("Erste Zeile eines längeren Absatzes, der weitergeht", row: 0, order: 0),
            line("und hier endet.", row: 1, width: 0.3, order: 1),
        ])
        let paragraph = try #require(ParagraphGrouping.paragraphs(of: lines).first)
        #expect(paragraph.lineIDs == lines.map(\.id))
        #expect(paragraph.rect == lines[0].rect.union(lines[1].rect))
        #expect(Set(lines.compactMap(\.paragraphID)).count == 1)
    }

    @Test("Eine Leerzeile, ein neuer Aufzählungspunkt, ein Farbwechsel oder ein nummerierter Eintrag beginnen neue Absätze")
    func breaks() {
        let texts = paragraphs([
            line("Lage:", row: 0, width: 0.1, order: 0),
            line("- Nordafrika", row: 1, width: 0.2, order: 1),
            line("- am Südrand der Sahara, vom Atlantischen Ozean bis zum", row: 2, order: 2),
            line("Roten Meer", row: 3, x: 0.08, width: 0.2, order: 3),
            line("Grüne Überschrift", row: 4, width: 0.4, order: 4, color: green),
            line("Neuer Absatz nach einer Leerzeile beginnt hier und", row: 6, order: 5),
            line("15 Niger", row: 7, width: 0.15, order: 6),
            line("6 Nigeria", row: 8, width: 0.15, order: 7),
        ])
        #expect(texts == [
            "Lage:", "- Nordafrika", "- am Südrand der Sahara, vom Atlantischen Ozean bis zum Roten Meer",
            "Grüne Überschrift", "Neuer Absatz nach einer Leerzeile beginnt hier und", "15 Niger", "6 Nigeria",
        ])
    }

    @Test("Zwei kurze Zeilen untereinander (Überschriften) bleiben getrennt, außer die zweite beginnt klein")
    func shortRows() {
        let long = line("Eine volle Zeile, damit die Seite eine typische Zeilenbreite hat", row: 10, order: 9)
        #expect(paragraphs([
            line("I Lebensraum Erde", row: 0, width: 0.3, order: 0, color: green),
            line("Das System Erde", row: 1, width: 0.25, order: 1, color: green), long,
        ]).prefix(2) == ["I Lebensraum Erde", "Das System Erde"])
        #expect(paragraphs([
            line("Veränderungen durch", row: 0, width: 0.2, order: 0),
            line("den Globalen Wandel", row: 1, width: 0.2, order: 1), long,
        ]).first == "Veränderungen durch den Globalen Wandel")
    }

    @Test("Spalten und Mindmaps: jede Zeile setzt den Absatz fort, unter dem sie steht, nicht die vorige Zeile der Lesereihenfolge")
    func columns() {
        let texts = paragraphs([
            line("Die Folgen der Um-", row: 0, x: 0.65, width: 0.27, order: 0),
            line("Veränderungen", row: 0.6, x: 0.05, width: 0.19, order: 1),
            line("weltveränderungen", row: 1, x: 0.65, width: 0.21, order: 2),
            line("durch den Glo-", row: 1.6, x: 0.05, width: 0.19, order: 3),
            line("belasten die Lebens-", row: 2, x: 0.65, width: 0.26, order: 4),
            line("balen Wandel", row: 2.6, x: 0.05, width: 0.18, order: 5),
        ])
        #expect(texts == ["Die Folgen der Umweltveränderungen belasten die Lebens-", "Veränderungen durch den Globalen Wandel"])
    }

    @Test("Teile einer Zeile nebeneinander (z. B. hinter einem Pfeil) gehören zum Absatz; Unleserliches bleibt eigener Absatz")
    func sameRowAndIllegible() {
        let texts = paragraphs([
            line("- unterer Teil: klimatische Prozesse", row: 0, width: 0.5, order: 0),
            line("für Klima verantwortlich", row: 0, x: 0.6, width: 0.3, order: 1),
            line("", row: 2, width: 0.05, order: 2, status: .illegible),
            line("Senegal", row: 2, x: 0.12, width: 0.15, order: 3),
        ])
        #expect(texts == ["- unterer Teil: klimatische Prozesse für Klima verantwortlich", "[unleserlich]", "Senegal"])
    }

    @Test("Gedruckter Text (ohne Stiftfarbe): weiter Zeilenabstand, Blocksatz-Stücke, hängender Einzug trennt Einträge")
    func printed() {
        func printed(_ text: String, y: Double, x: Double, width: Double, order: Int) -> RecognizedLine {
            RecognizedLine(text: text, rect: NormalizedRect(x: x, y: y, width: width, height: 0.018), color: nil, order: order)
        }
        let texts = paragraphs([
            printed("Das Aralsee-Syndrom: massive Umweltschädigungen durch", y: 0.29, x: 0.09, width: 0.78, order: 0),
            printed("wasserbauliche", y: 0.323, x: 0.13, width: 0.17, order: 1),
            printed("Großprojekte (z.B.", y: 0.324, x: 0.37, width: 0.26, order: 2),
            printed("Staudammbau);", y: 0.322, x: 0.69, width: 0.18, order: 3),
            printed("soziale Probleme", y: 0.355, x: 0.13, width: 0.3, order: 4),
            printed("Das Kleine Tiger-Syndrom: massive Umweltbelastungen", y: 0.388, x: 0.09, width: 0.78, order: 5),
            printed("eines rasanten Wirtschaftswachstums", y: 0.42, x: 0.13, width: 0.42, order: 6),
        ])
        #expect(texts == [
            "Das Aralsee-Syndrom: massive Umweltschädigungen durch wasserbauliche Großprojekte (z.B. Staudammbau); soziale Probleme",
            "Das Kleine Tiger-Syndrom: massive Umweltbelastungen eines rasanten Wirtschaftswachstums",
        ])
    }

    @Test("Zeilen ohne Absatz-ID (alte Digitalisierungen) sind je ein eigener Absatz; die ID wird nur gespeichert, wenn gesetzt")
    func legacy() throws {
        let lines = [line("eins", row: 0, order: 0), line("zwei", row: 1, order: 1)]
        #expect(ParagraphGrouping.paragraphs(of: lines).map(\.text) == ["eins", "zwei"])
        let encoded = try JSONEncoder().encode(lines[0])
        #expect(!String(decoding: encoded, as: UTF8.self).contains("paragraphID"))
        let grouped = ParagraphGrouping.assign(lines)
        let roundTrip = try JSONDecoder().decode(RecognizedLine.self, from: JSONEncoder().encode(grouped[0]))
        #expect(roundTrip.paragraphID == grouped[0].paragraphID)
    }

    @Test("Listenpunkte werden erkannt")
    func listMarkers() {
        for item in ["- Nordafrika", "• Lithosphäre", "1. Geosphären", "15 Niger", "→ hier", "a) erstens", "– Strich"] {
            #expect(ParagraphGrouping.startsListItem(item), "\(item)")
        }
        for prose in ["Nordafrika", "2er-Gruppe", "1990er Jahre", "Die 3 Geosphären"] {
            #expect(!ParagraphGrouping.startsListItem(prose), "\(prose)")
        }
    }
}
