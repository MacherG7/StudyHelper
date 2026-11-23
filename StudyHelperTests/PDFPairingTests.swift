import Foundation
import StudyCore
import StudyImport
import Testing
@testable import StudyHelper

@Suite("PDF-Paarung (bearbeitbar + reduziert)")
struct PDFPairingTests {
    private static let a4 = PageSize(width: 595.28, height: 841.89)
    private static let letter = PageSize(width: 612, height: 792)

    /// A picked Goodnotes export with the given structure (no real PDF bytes needed for the pairing check).
    private func pdf(_ name: String, _ variant: GoodnotesVariant, pages: Int = 3, size: PageSize = a4) -> PickedPDF {
        let goodnotesPages = (0..<pages).map { GoodnotesPage(index: $0, size: size) }
        return PickedPDF(
            name: name, data: Data("%PDF".utf8), pageCount: pages, pageSizes: Array(repeating: size, count: pages),
            variant: variant, document: variant == .other ? nil : GoodnotesDocument(variant: variant, pages: goodnotesPages))
    }

    @Test("Eine Datei allein: Zustand single, keine reduzierte Datei")
    func single() throws {
        let pairing = try #require(PDFPairing(files: [pdf("Notiz.pdf", .editable)]))
        guard case .single = pairing.state else { Issue.record("erwartet: single"); return }
        #expect(pairing.reduced == nil)
        #expect(PDFPairing(files: []) == nil)
    }

    @Test("Bearbeitbar und reduziert derselben Notiz sind kompatibel, auch in umgekehrter Reihenfolge")
    func compatible() throws {
        let editable = pdf("Notiz.pdf", .editable)
        let reduced = pdf("Notiz (reduziert).pdf", .reduced)
        for files in [[editable, reduced], [reduced, editable]] {
            let pairing = try #require(PDFPairing(files: files))
            guard case .compatible = pairing.state else { Issue.record("erwartet: compatible"); return }
            #expect(pairing.main.name == "Notiz.pdf")
            #expect(pairing.reduced?.name == "Notiz (reduziert).pdf")
        }
    }

    @Test("Andere Seitenzahl: nicht kompatibel, nur die bearbeitbare Datei wird importiert")
    func pageCountMismatch() throws {
        let pairing = try #require(PDFPairing(files: [pdf("A.pdf", .editable), pdf("B.pdf", .reduced, pages: 1)]))
        guard case .incompatible(let reason) = pairing.state else { Issue.record("erwartet: incompatible"); return }
        #expect(reason.contains("Seitenzahlen") && reason.contains("bearbeitbar: 3, reduziert: 1"))
        #expect(pairing.reduced == nil)
        #expect(pairing.main.name == "A.pdf")
    }

    @Test("Andere Seitengröße: nicht kompatibel")
    func pageSizeMismatch() throws {
        let pairing = try #require(PDFPairing(files: [pdf("A.pdf", .editable), pdf("B.pdf", .reduced, size: Self.letter)]))
        guard case .incompatible(let reason) = pairing.state else { Issue.record("erwartet: incompatible"); return }
        #expect(reason.contains("Seitengröße von Seite 1"))
        #expect(pairing.reduced == nil)
        #expect(pairing.main.name == "A.pdf")
    }

    @Test("Zwei Dateien ohne bearbeitbar/reduziert-Paar lassen sich nicht zuordnen")
    func notAPair() throws {
        for files in [
            [pdf("A.pdf", .reduced), pdf("B.pdf", .reduced)],
            [pdf("A.pdf", .editable), pdf("B.pdf", .editable)],
            [pdf("A.pdf", .editable), pdf("B.pdf", .other)],
        ] {
            let pairing = try #require(PDFPairing(files: files))
            guard case .incompatible(let reason) = pairing.state else { Issue.record("erwartet: incompatible"); return }
            #expect(reason.contains("bearbeitbares und ein reduziertes"))
            #expect(pairing.reduced == nil)
            #expect(pairing.main.name == "A.pdf", "importiert wird die erste Datei")
        }
    }

    @Test("Goodnotes-Dateien und kaputte PDFs werden mit deutscher Meldung abgelehnt")
    func rejectedFiles() {
        #expect(PDFLoader.isGoodnotesFile(URL(fileURLWithPath: "/tmp/Notiz.goodnotes")))
        #expect(!PDFLoader.isGoodnotesFile(URL(fileURLWithPath: "/tmp/Notiz.pdf")))
        #expect(throws: PDFLoadError.self) { try PDFLoader.inspect(data: Data("kein pdf".utf8), name: "x.pdf") }
        #expect(PDFLoadError.notAPDF("x.pdf").errorDescription == "Die Datei „x.pdf“ ist kein lesbares PDF.")
    }
}
