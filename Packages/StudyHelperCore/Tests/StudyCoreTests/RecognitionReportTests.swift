import Foundation
import StudyCore
import Testing

/// Fehlerberichte der Texterkennung (Entwicklermodus): Modell, JSON, Chat-Text.
@Suite("Erkennungsfehler-Berichte")
struct RecognitionReportTests {
    let importID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let pageSize = PageSize(width: 595, height: 842)
    let createdAt = try! Date("2026-11-26T14:00:00Z", strategy: Date.ISO8601FormatStyle())

    func line(_ text: String, order: Int, y: Double, x: Double = 0.06, width: Double = 0.9,
              corrected: String? = nil) -> RecognizedLine {
        RecognizedLine(
            text: text, rect: NormalizedRect(x: x, y: y, width: width, height: 0.03), order: order,
            isUserCorrected: corrected != nil, recognizedText: corrected)
    }

    var pageLines: [RecognizedLine] {
        [
            line("Überschrift", order: 0, y: 0.05),
            line("Die Eingrifte des Menschen", order: 1, y: 0.12),
            line("wirken weltweit zu Schädigungen", order: 2, y: 0.15),
            line("Globaler Wandel zusammen.", order: 3, y: 0.18),
            line("Ende", order: 4, y: 0.21),
        ]
    }

    func sampleReport() -> RecognitionReport {
        let lines = pageLines
        let misread = RecognitionReportEntry.make(
            importID: importID, page: 6, pageSize: pageSize, selectedLines: [lines[1]], allLines: lines,
            kind: .misread, expected: "Die Eingriffe des Menschen", method: .goodnotesInkLayers, engine: "3",
            createdAt: createdAt)
        let order = RecognitionReportEntry.make(
            importID: importID, page: 6, pageSize: pageSize, selectedLines: [lines[3]], allLines: lines,
            kind: .order, after: lines[1], method: .goodnotesInkLayers, engine: "3", createdAt: createdAt)
        let missing = RecognitionReportEntry.make(
            importID: importID, page: 6, pageSize: pageSize, selectedLines: [], allLines: lines, kind: .missing,
            expected: "Stichwort am Rand", note: "Pfeil daneben", drawnRect: NormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.05),
            method: .goodnotesInkLayers, engine: "3", imageJPEG: Data([0xFF, 0xD8, 0xFF]), createdAt: createdAt)
        return RecognitionReport(
            createdAt: createdAt,
            app: RecognitionReportApp(version: "0.0.2.7", commit: "abc1234", os: "iOS 27.2", device: "iPhone17,1"),
            imports: [RecognitionReportImport(
                id: importID, fileName: "GPG_bearbeitbar.pdf", kind: "pdf", variant: .editable, pageCount: 17)],
            entries: [misread, order, missing])
    }

    // MARK: JSON

    @Test("Bericht lässt sich kodieren und wieder dekodieren")
    func roundTrip() throws {
        let report = sampleReport()
        let decoded = try RecognitionReport.decode(from: report.encodedJSON())
        #expect(decoded == report)
    }

    @Test("JSON enthält Format, Version und Schlüssel wie festgelegt")
    func jsonKeys() throws {
        let data = try sampleReport().encodedJSON()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["format"] as? String == "studyhelper-recognition-report")
        #expect(root["version"] as? Int == 1)
        #expect(root["createdAt"] as? String == "2026-11-26T14:00:00Z")
        let app = try #require(root["app"] as? [String: Any])
        #expect(app["commit"] as? String == "abc1234")
        let imports = try #require(root["imports"] as? [[String: Any]])
        #expect(imports[0]["goodnotesVariant"] as? String == "editable")
        #expect(imports[0]["pageCount"] as? Int == 17)
        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(entries.count == 3)
        let first = entries[0]
        #expect(first["kind"] as? String == "misread")
        #expect(first["source"] as? String == "report")
        #expect(first["method"] as? String == "goodnotesInkLayers")
        #expect(first["page"] as? Int == 1 + 5)
        #expect((first["pageSize"] as? [String: Any])?["width"] as? Double == 595)
        #expect(first["after"] is NSNull)
        #expect(first["note"] is NSNull)
        #expect(first["imageJPEGBase64"] is NSNull)
        #expect(entries[2]["imageJPEGBase64"] as? String == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        #expect((entries[1]["after"] as? [String: Any])?["order"] as? Int == 1)
    }

    @Test("Datumswerte sind UTC mit Z, Schrägstriche bleiben unmaskiert")
    func datesAndSlashes() throws {
        var report = sampleReport()
        report.entries[0].note = "a/b"
        let text = try #require(String(data: report.encodedJSON(), encoding: .utf8))
        #expect(text.contains("\"createdAt\" : \"2026-11-26T14:00:00Z\""))
        #expect(text.contains("a/b"))
        #expect(!text.contains("\\/"))
    }

    @Test("Optionale Werte: null und fehlend werden gleich gelesen")
    func nullVersusOmitted() throws {
        let withNull = """
        {"format":"studyhelper-recognition-report","version":1,"createdAt":"2026-11-26T14:00:00Z",
         "app":{"version":"0.0.2.7","commit":null,"os":null,"device":null},"imports":[],
         "entries":[{"id":"22222222-2222-2222-2222-222222222222","createdAt":"2026-11-26T14:00:00Z",
         "importID":"11111111-1111-1111-1111-111111111111","page":2,
         "pageSize":{"width":595,"height":842},"rect":{"x":0.1,"y":0.2,"width":0.5,"height":0.03},
         "kind":"misread","recognized":null,"expected":null,"note":null,"lines":[],"after":null,
         "context":{"before":null,"after":null},"source":"report","method":null,"engine":null,
         "imageJPEGBase64":null}]}
        """
        let omitted = """
        {"format":"studyhelper-recognition-report","version":1,"createdAt":"2026-11-26T14:00:00Z",
         "app":{"version":"0.0.2.7"},
         "entries":[{"id":"22222222-2222-2222-2222-222222222222","createdAt":"2026-11-26T14:00:00Z",
         "importID":"11111111-1111-1111-1111-111111111111","page":2,
         "pageSize":{"width":595,"height":842},"rect":{"x":0.1,"y":0.2,"width":0.5,"height":0.03},
         "kind":"misread"}]}
        """
        let a = try RecognitionReport.decode(from: Data(withNull.utf8))
        let b = try RecognitionReport.decode(from: Data(omitted.utf8))
        #expect(a == b)
        #expect(a.entries.count == 1)
        #expect(a.entries[0].recognized == nil)
        #expect(a.entries[0].after == nil)
        #expect(a.entries[0].context == RecognitionReportContext())
        #expect(a.entries[0].source == .report)
        #expect(a.entries[0].imageJPEG == nil)
    }

    @Test("Unbekannte Felder werden ignoriert, Datum mit Sekundenbruchteilen wird gelesen")
    func lenientDecoding() throws {
        let json = """
        {"format":"studyhelper-recognition-report","version":1,"createdAt":"2026-11-26T14:00:00.250Z",
         "futureField":42,"app":{"version":"1","extra":true},"imports":[],"entries":[]}
        """
        let report = try RecognitionReport.decode(from: Data(json.utf8))
        #expect(abs(report.createdAt.timeIntervalSince(createdAt) - 0.25) < 0.001)
    }

    @Test("Falsches Format wird mit deutscher Meldung abgelehnt")
    func rejectsWrongFormat() throws {
        let json = #"{"format":"anderes-format","version":1}"#
        #expect(throws: RecognitionReportError.wrongFormat("anderes-format")) {
            try RecognitionReport.decode(from: Data(json.utf8))
        }
        let message = RecognitionReportError.wrongFormat("anderes-format").errorDescription ?? ""
        #expect(message.contains("keine StudyHelper-Fehlerdatei"))
    }

    @Test("Version 2 wird mit deutscher Meldung abgelehnt")
    func rejectsVersion2() throws {
        let json = #"{"format":"studyhelper-recognition-report","version":2,"entries":[]}"#
        #expect(throws: RecognitionReportError.unsupportedVersion(2)) {
            try RecognitionReport.decode(from: Data(json.utf8))
        }
        let message = RecognitionReportError.unsupportedVersion(2).errorDescription ?? ""
        #expect(message.contains("Version 2"))
    }

    @Test("Kaputtes JSON ergibt einen lesbaren Fehler")
    func rejectsGarbage() {
        #expect(throws: RecognitionReportError.self) {
            try RecognitionReport.decode(from: Data("kein json".utf8))
        }
    }

    @Test("Unbekannte Art eines Eintrags wird zu „Sonstiges“")
    func unknownKindBecomesOther() throws {
        let json = """
        {"format":"studyhelper-recognition-report","version":1,"entries":[
         {"id":"22222222-2222-2222-2222-222222222222","kind":"zukunftsart","source":"irgendwas","page":1}]}
        """
        let report = try RecognitionReport.decode(from: Data(json.utf8))
        #expect(report.entries[0].kind == .other)
        #expect(report.entries[0].source == .report)
    }

    @Test("Anzeigenamen der Arten sind deutsch")
    func displayNames() {
        #expect(RecognitionReportKind.misread.displayName == "Falsch gelesen")
        #expect(RecognitionReportKind.missing.displayName == "Fehlt")
        #expect(RecognitionReportKind.order.displayName == "Reihenfolge falsch")
        #expect(RecognitionReportKind.split.displayName == "Falsch getrennt/zusammengefügt")
        #expect(RecognitionReportKind.highlight.displayName == "Hervorhebung falsch")
        #expect(RecognitionReportKind.other.displayName == "Sonstiges")
    }

    // MARK: Einträge erzeugen

    @Test("make: Bereich ist die Vereinigung, erkannter Text in Lesereihenfolge, Umgebung aus den Nachbarzeilen")
    func makeUnionContextRecognized() {
        let lines = pageLines
        // Selected out of order on purpose.
        let entry = RecognitionReportEntry.make(
            importID: importID, page: 6, pageSize: pageSize, selectedLines: [lines[3], lines[2]], allLines: lines.shuffled(),
            kind: .split, expected: "a", note: "n", createdAt: createdAt)
        #expect(entry.recognized == "wirken weltweit zu Schädigungen\nGlobaler Wandel zusammen.")
        #expect(entry.lines.map(\.order) == [2, 3])
        #expect(abs(entry.rect.y - 0.15) < 1e-9)
        #expect(abs(entry.rect.height - 0.06) < 1e-9)
        #expect(abs(entry.rect.width - 0.9) < 1e-9)
        #expect(entry.context.before == "Die Eingrifte des Menschen")
        #expect(entry.context.after == "Ende")
        #expect(entry.after == nil)
        #expect(entry.source == .report)
        #expect(entry.page == 6)
    }

    @Test("make: am Seitenanfang und -ende fehlt die jeweilige Umgebung")
    func makeContextAtEdges() {
        let lines = pageLines
        let first = RecognitionReportEntry.make(
            importID: importID, page: 1, pageSize: pageSize, selectedLines: [lines[0]], allLines: lines, kind: .misread)
        #expect(first.context.before == nil)
        #expect(first.context.after == "Die Eingrifte des Menschen")
        let last = RecognitionReportEntry.make(
            importID: importID, page: 1, pageSize: pageSize, selectedLines: [lines[4]], allLines: lines, kind: .misread)
        #expect(last.context.after == nil)
    }

    @Test("make: „after“ bleibt nur bei Reihenfolge-Fehlern erhalten")
    func makeAfterOnlyForOrder() {
        let lines = pageLines
        let order = RecognitionReportEntry.make(
            importID: importID, page: 1, pageSize: pageSize, selectedLines: [lines[3]], allLines: lines,
            kind: .order, after: lines[1])
        #expect(order.after?.id == lines[1].id)
        #expect(order.after?.order == 1)
        let misread = RecognitionReportEntry.make(
            importID: importID, page: 1, pageSize: pageSize, selectedLines: [lines[3]], allLines: lines,
            kind: .misread, after: lines[1])
        #expect(misread.after == nil)
    }

    @Test("make: „Fehlt“ ohne Zeilen nutzt den gezeichneten Bereich")
    func makeMissingUsesDrawnRect() {
        let drawn = NormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.05)
        let entry = RecognitionReportEntry.make(
            importID: importID, page: 3, pageSize: pageSize, selectedLines: [], allLines: pageLines,
            kind: .missing, expected: "Randnotiz", drawnRect: drawn)
        #expect(entry.rect == drawn)
        #expect(entry.recognized == nil)
        #expect(entry.lines.isEmpty)
        #expect(entry.context == RecognitionReportContext())
    }

    @Test("corrections: nur korrigierte Zeilen mit abweichendem Text")
    func correctionsOnlyChanged() {
        let lines: [RecognizedLine] = [
            line("Eingriffe", order: 0, y: 0.1, corrected: "Eingrifte"),
            line("unverändert", order: 1, y: 0.2),
            line("gleich", order: 2, y: 0.3, corrected: "gleich"),
            {
                // Corrected by the user, but no raw text kept.
                var l = line("ohne Rohtext", order: 3, y: 0.4)
                l.isUserCorrected = true
                return l
            }(),
            {
                // Raw text differs but the line was not marked as corrected.
                var l = line("neu", order: 4, y: 0.5)
                l.recognizedText = "alt"
                return l
            }(),
            line("Wandel", order: 5, y: 0.6, corrected: "Wandl"),
        ]
        let entries = RecognitionReportEntry.corrections(
            from: lines, importID: importID, page: 4, pageSize: pageSize, method: .vision, engine: "3",
            createdAt: createdAt)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.source == .correction && $0.kind == .misread && $0.page == 4 })
        #expect(entries[0].recognized == "Eingrifte")
        #expect(entries[0].expected == "Eingriffe")
        #expect(entries[0].lines.first?.text == "Eingrifte")
        #expect(entries[0].rect == lines[0].rect)
        #expect(entries[0].context.before == nil)
        #expect(entries[0].context.after == "unverändert")
        #expect(entries[0].method == "vision")
        #expect(entries[1].recognized == "Wandl")
        #expect(entries[1].expected == "Wandel")
    }

    // MARK: Chat-Text

    @Test("Chat-Text enthält Kopfzeile, Quelle und die erwarteten Einträge")
    func chatTextContent() {
        let text = sampleReport().chatText()
        let rows = text.components(separatedBy: "\n")
        #expect(rows[0] == "StudyHelper-Erkennungsfehler · App 0.0.2.7 (abc1234) · 26.11.2026")
        #expect(rows[1] == "GPG_bearbeitbar.pdf (Goodnotes bearbeitbar, 17 Seiten)")
        #expect(rows[2] == "- S. 6 · Falsch gelesen · „Die Eingrifte des Menschen“ → „Die Eingriffe des Menschen“ · Bereich x 0.06 y 0.12 b 0.90 h 0.03")
        #expect(rows[3] == "- S. 6 · Reihenfolge falsch · „Globaler Wandel zusammen.“ gehört hinter „Die Eingrifte des Menschen“")
        #expect(rows[4] == "- S. 6 · Fehlt · Bereich x 0.70 y 0.40 b 0.20 h 0.05 · erwartet „Stichwort am Rand“ · Notiz: Pfeil daneben")
        #expect(rows[5] == "JSON-Kurzform:")
        #expect(rows.count == 7)
    }

    @Test("Chat-Text kürzt lange erkannte Texte, der erwartete Text bleibt vollständig")
    func chatTextTruncation() {
        let long = String(repeating: "lang ", count: 40)
        let expected = String(repeating: "richtig ", count: 30) + "Ende"
        let entry = RecognitionReportEntry(
            importID: importID, page: 1, pageSize: pageSize, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 0.1),
            kind: .misread, recognized: long, expected: expected)
        let text = RecognitionReport(app: RecognitionReportApp(version: "1"), entries: [entry]).chatText()
        let row = text.components(separatedBy: "\n").first { $0.hasPrefix("- S. 1") } ?? ""
        #expect(row.contains(expected))
        #expect(!row.contains(long))
        #expect(row.contains("…"))
    }

    @Test("Chat-Text: Mehrzeiliger Text bleibt in einer Zeile")
    func chatTextNewlines() {
        let entry = RecognitionReportEntry(
            importID: importID, page: 1, pageSize: pageSize, rect: .zero, kind: .split,
            recognized: "a\nb", expected: "ab", note: "x\ny")
        let text = RecognitionReport(app: RecognitionReportApp(version: "1"), entries: [entry]).chatText()
        let rows = text.components(separatedBy: "\n")
        #expect(rows.contains { $0.contains("„a ⏎ b“ → „ab“") && $0.contains("Notiz: x ⏎ y") })
    }

    @Test("Chat-Text: Kurzform-JSON ergibt dieselben Einträge ohne Bilder")
    func chatTextCompactJSONParsesBack() throws {
        let report = sampleReport()
        let text = report.chatText()
        let lastLine = try #require(text.components(separatedBy: "\n").last)
        #expect(!lastLine.contains("\n"))
        let parsed = try #require(RecognitionReport.entries(fromChatText: text))
        #expect(parsed == report.entries.map(\.withoutImage))
        #expect(parsed.allSatisfy { $0.imageJPEG == nil })
        // Direct parse of the last line, as a script would do.
        let plain = JSONDecoder()
        plain.dateDecodingStrategy = .iso8601
        let direct = try plain.decode([RecognitionReportEntry].self, from: Data(lastLine.utf8))
        #expect(direct == parsed)
        // Compact form drops nulls.
        #expect(!lastLine.contains("null"))
        #expect(!text.contains(Data([0xFF, 0xD8, 0xFF]).base64EncodedString()))
    }

    @Test("Chat-Text mit Bildern enthält das Bild in der Kurzform")
    func chatTextWithImages() throws {
        let report = sampleReport()
        let text = report.chatText(includeImages: true)
        let parsed = try #require(RecognitionReport.entries(fromChatText: text))
        #expect(parsed == report.entries)
    }

    @Test("Chat-Text: Einträge einer unbekannten Quelle werden trotzdem aufgeführt")
    func chatTextUnknownImport() {
        var report = sampleReport()
        report.imports = []
        let text = report.chatText()
        #expect(text.contains("- S. 6 · Falsch gelesen"))
    }

    @Test("Chat-Text: Korrekturen sind gekennzeichnet")
    func chatTextCorrectionMarker() {
        let entries = RecognitionReportEntry.corrections(
            from: [line("Eingriffe", order: 0, y: 0.1, corrected: "Eingrifte")], importID: importID, page: 2,
            pageSize: pageSize)
        let text = RecognitionReport(app: RecognitionReportApp(version: "1"), entries: entries).chatText()
        #expect(text.contains("Falsch gelesen (Korrektur) · „Eingrifte“ → „Eingriffe“"))
    }

    // MARK: Beispieldatei

    @Test("Beispieldatei schreiben (nur mit REPORT_SAMPLE_OUT)")
    func writeSample() throws {
        guard let path = ProcessInfo.processInfo.environment["REPORT_SAMPLE_OUT"], !path.isEmpty else { return }
        try sampleReport().encodedJSON().write(to: URL(fileURLWithPath: path))
    }
}
