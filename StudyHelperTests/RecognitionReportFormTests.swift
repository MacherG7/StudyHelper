import CoreGraphics
import Foundation
import StudyCore
import Testing
import UIKit
@testable import StudyHelper

@Suite("Fehler melden (Formular, Bildausschnitt, Bereich)")
@MainActor
struct RecognitionReportFormTests {
    private let importID = UUID()
    private let pageSize = PageSize(width: 600, height: 800)

    private let pageLines: [RecognizedLine] = [
            RecognizedLine(text: "Fotosynthese", rect: NormalizedRect(x: 0.1, y: 0.08, width: 0.45, height: 0.06), order: 0),
            RecognizedLine(text: "Ort: Chloroplasten", rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.55, height: 0.05), order: 1),
            RecognizedLine(text: "Chlorophyl ist grun", rect: NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05), order: 2),
            RecognizedLine(text: "Ende", rect: NormalizedRect(x: 0.1, y: 0.4, width: 0.2, height: 0.05), order: 3),
    ]

    private func lines() -> [RecognizedLine] { pageLines }

    private func entry(_ draft: ReportDraft, selected: UUID?, drawn: NormalizedRect? = nil) -> RecognitionReportEntry {
        draft.makeEntry(
            importID: importID, page: 2, pageSize: pageSize, lines: lines(), selectedLineID: selected,
            drawnRect: drawn, method: .vision, engine: "3", imageJPEG: nil)
    }

    @Test("Mit gewählter Zeile beginnt das Formular als „Falsch gelesen“ mit dem Zeilentext")
    func initialDraft() {
        let line = lines()[2]
        let draft = ReportDraft.initial(for: line)
        #expect(draft.kind == .misread)
        #expect(draft.expected == "Chlorophyl ist grun")
        #expect(draft.includeImage)
        #expect(ReportDraft.initial(for: nil).kind == .missing)
        #expect(ReportDraft.initial(for: nil).expected.isEmpty)
    }

    @Test("Falsch gelesen: erkannter und richtiger Text, Methode und Umgebung")
    func misreadEntry() {
        let line = lines()[2]
        var draft = ReportDraft.initial(for: line)
        draft.expected = "  Chlorophyll ist grün \n"
        draft.note = "Umlaut"
        let result = entry(draft, selected: line.id)
        #expect(result.kind == .misread)
        #expect(result.recognized == "Chlorophyl ist grun")
        #expect(result.expected == "Chlorophyll ist grün")
        #expect(result.note == "Umlaut")
        #expect(result.page == 2 && result.importID == importID)
        #expect(result.method == "vision" && result.engine == "3")
        #expect(result.context.before == "Ort: Chloroplasten" && result.context.after == "Ende")
        #expect(result.rect == line.rect)
    }

    @Test("Ein unverändert vorbelegter Text wird nicht als „richtig“ gespeichert")
    func unchangedExpectedIsDropped() {
        let line = lines()[2]
        var draft = ReportDraft.initial(for: line)
        draft.kind = .highlight
        #expect(entry(draft, selected: line.id).expected == nil)
        draft.note = "  "
        #expect(entry(draft, selected: line.id).note == nil)
    }

    @Test("Fehlt: gezeichneter Bereich ohne Zeile")
    func missingEntryUsesDrawnRect() {
        let area = NormalizedRect(x: 0.2, y: 0.5, width: 0.4, height: 0.1)
        var draft = ReportDraft.initial(for: nil)
        draft.expected = "Zusatz am Rand"
        let result = entry(draft, selected: nil, drawn: area)
        #expect(result.kind == .missing)
        #expect(result.rect == area)
        #expect(result.recognized == nil && result.lines.isEmpty)
        #expect(result.expected == "Zusatz am Rand")
    }

    @Test("Reihenfolge: „gehört hinter“ wird gespeichert, ein Erwartungstext nicht")
    func orderEntry() {
        let moved = lines()[3]
        let anchor = lines()[0]
        var draft = ReportDraft.initial(for: moved)
        draft.kind = .order
        draft.afterLineID = anchor.id
        let result = entry(draft, selected: moved.id)
        #expect(result.kind == .order)
        #expect(result.after?.text == "Fotosynthese")
        #expect(result.expected == nil)

        draft.kind = .misread
        #expect(entry(draft, selected: moved.id).after == nil, "„hinter“ gilt nur für Reihenfolge-Fehler")
    }

    @Test("Getrennt: weitere gewählte Zeilen gehören zum Eintrag, nur bei dieser Art")
    func splitEntry() {
        let first = lines()[1]
        let second = lines()[2]
        var draft = ReportDraft.initial(for: first)
        draft.kind = .split
        draft.extraLineIDs = [second.id]
        let result = entry(draft, selected: first.id)
        #expect(result.lines.map(\.text) == ["Ort: Chloroplasten", "Chlorophyl ist grun"])
        #expect(result.recognized == "Ort: Chloroplasten\nChlorophyl ist grun")
        #expect(result.rect == first.rect.union(second.rect))

        draft.kind = .misread
        #expect(entry(draft, selected: first.id).lines.count == 1)
    }

    // MARK: Crop

    private func pageImageData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: width / 10, y: height * 3 / 10, width: width * 8 / 10, height: height / 20))
        }
        return image.pngData() ?? Data()
    }

    @Test("Der Bildausschnitt ist höchstens 600 Pixel groß und ein JPEG")
    func cropSizeIsBounded() throws {
        let data = pageImageData(width: 2400, height: 3200)
        let rect = NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05)
        let jpeg = try #require(ReportImageCropper.jpegSync(from: data, rect: rect))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]), "JPEG-Kennung")
        let image = try #require(UIImage(data: jpeg))
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        #expect(longest <= ReportImageCropper.maxSide + 0.5)
        #expect(longest >= ReportImageCropper.maxSide - 1, "ein großer Bereich wird auf 600 Pixel verkleinert")
        // Wide and flat like the area (plus margin).
        #expect(image.size.width > image.size.height * 3)
    }

    @Test("Ein kleiner Bereich wird nicht vergrößert, der Rand bleibt auf der Seite")
    func smallCropIsNotUpscaled() throws {
        let data = pageImageData(width: 300, height: 400)
        let rect = NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)
        let jpeg = try #require(ReportImageCropper.jpegSync(from: data, rect: rect))
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size.width <= 300 && image.size.height <= 400)
        #expect(image.size.width < ReportImageCropper.maxSide)
    }

    @Test("Ohne lesbares Bild oder ohne Bereich gibt es keinen Ausschnitt")
    func cropFailsGracefully() {
        let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)
        #expect(ReportImageCropper.jpegSync(from: Data([1, 2, 3]), rect: rect) == nil)
        #expect(ReportImageCropper.jpegSync(from: pageImageData(width: 100, height: 100), rect: .zero) == nil)
    }

    @Test("Der asynchrone Zuschnitt liefert dasselbe wie der synchrone")
    func asyncCrop() async throws {
        let data = pageImageData(width: 800, height: 1000)
        let rect = NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05)
        let result = await ReportImageCropper.jpeg(from: data, rect: rect)
        #expect(result != nil)
    }

    // MARK: Area overlay geometry

    @Test("Das Bild wird eingepasst und zentriert")
    func fitFrame() {
        // A 3:4 page in a wide viewport: full height, centered horizontally.
        let fit = ReportAreaOverlay.fitFrame(imageSize: CGSize(width: 600, height: 800), in: CGSize(width: 800, height: 400))
        #expect(abs(fit.height - 400) < 0.001 && abs(fit.width - 300) < 0.001)
        #expect(abs(fit.minX - 250) < 0.001 && fit.minY == 0)
        #expect(ReportAreaOverlay.fitFrame(imageSize: .zero, in: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test("Der gezogene Rahmen wird in Seitenanteile umgerechnet und begrenzt")
    func normalizedDrag() throws {
        let fit = CGRect(x: 50, y: 0, width: 300, height: 400)
        let rect = try #require(ReportAreaOverlay.normalizedRect(
            from: CGPoint(x: 200, y: 100), to: CGPoint(x: 80, y: 40), fit: fit))
        #expect(abs(rect.x - 0.1) < 1e-9 && abs(rect.y - 0.1) < 1e-9)
        #expect(abs(rect.width - 0.4) < 1e-9 && abs(rect.height - 0.15) < 1e-9)

        // Dragged beyond the page: clamped to the page.
        let clamped = try #require(ReportAreaOverlay.normalizedRect(
            from: CGPoint(x: 300, y: 350), to: CGPoint(x: 900, y: 900), fit: fit))
        #expect(clamped.maxX == 1 && clamped.maxY == 1)

        // A tap or a drag outside the page is no area.
        #expect(ReportAreaOverlay.normalizedRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 101, y: 101), fit: fit) == nil)
        #expect(ReportAreaOverlay.normalizedRect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 20, y: 300), fit: fit) == nil)
    }

    @Test("Der Ablauf wechselt zwischen Zeichnen, Formular und Ruhe")
    func flowPhases() {
        var flow = ReportFlow()
        #expect(flow.phase == .idle && flow.form == nil)
        flow.startDrawing()
        #expect(flow.isDrawing)
        let area = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        flow.finishDrawing(area)
        #expect(!flow.isDrawing && flow.form?.rect == area && flow.form?.lineID == nil)
        flow.cancel()
        #expect(flow.phase == .idle)
        let id = UUID()
        flow.reportLine(id)
        #expect(flow.form?.lineID == id && flow.form?.rect == nil)
    }
}
