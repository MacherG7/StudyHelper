import CoreGraphics
import Foundation
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Pipeline: Logik mit Mock-Erkenner")
struct PipelineMockTests {
    func pipeline(
        _ recognizer: CountingRecognizer, settings: PipelineSettings = PipelineSettings()
    ) -> DigitizationPipeline {
        DigitizationPipeline(
            recognizer: recognizer, environment: testEnvironment, settings: settings,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    @Test("Standard: Mehrfacherkennung aus, genau ein Durchlauf")
    func defaultSinglePass() async throws {
        #expect(PipelineSettings().multiPass == false)
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Fotosynthese ist wichtig")) }
        let page = try await pipeline(recognizer).digitizeImage(blankImage())
        #expect(recognizer.callCount == 1)
        #expect(page.result.metadata.passes == 1)
        #expect(page.result.lines.map(\.text) == ["Fotosynthese ist wichtig"])
        #expect(!page.result.lines[0].needsReview)
    }

    @Test("Metadaten: Methode, Version, System, Gerät, Datum, Anzahl eigener Wörter")
    func metadata() async throws {
        let recognizer = CountingRecognizer { _, _, _ in
            TextRecognitionOutput(lines: [mockLine("Text")], engineVersion: "VNRecognizeTextRequest rev 3", method: .vision)
        }
        let settings = PipelineSettings(customWords: ["Thylakoid", "Stroma"])
        let page = try await pipeline(recognizer, settings: settings).digitizeImage(blankImage(width: 400, height: 600))
        let meta = page.result.metadata
        #expect(meta.method == .vision)
        #expect(meta.engineVersion == "VNRecognizeTextRequest rev 3")
        #expect(meta.osVersion == "macOS 27.0" && meta.deviceModel == "TestMac1,1")
        #expect(meta.date == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(meta.customWordsCount == 2)
        #expect(!meta.usedReducedPDF)
        #expect(page.result.pageSize == PageSize(width: 400, height: 600))
        #expect(page.pageIndex == 0)
        #expect(page.imageData.map { Array($0.prefix(2)) } == [0xFF, 0xD8], "JPEG des Bildes")
    }

    @Test("Eigene Wörter und Sprachen erreichen den Erkenner")
    func customWordsPassedThrough() async throws {
        let recognizer = CountingRecognizer()
        let settings = PipelineSettings(customWords: ["Thylakoidmembran"], languages: ["de-DE", "en-US"], maximumCandidates: 5)
        _ = try await pipeline(recognizer, settings: settings).digitizeImage(blankImage())
        let options = try #require(recognizer.calls.first?.options)
        #expect(options.customWords == ["Thylakoidmembran"])
        #expect(options.languages == ["de-DE", "en-US"])
        #expect(options.maximumCandidates == 5)
        #expect(options.usesLanguageCorrection)
    }

    @Test("Mehrfacherkennung: zwei Durchläufe, zweiter auf verkleinertem Bild")
    func multiPassCalls() async throws {
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Chlorophyll ist grün")) }
        let page = try await pipeline(recognizer, settings: PipelineSettings(multiPass: true)).digitizeImage(blankImage(width: 1000, height: 1000))
        #expect(recognizer.callCount == 2)
        #expect(recognizer.calls[0].imageWidth == 1000)
        #expect(recognizer.calls[1].imageWidth == 700, "0,7-faches Bild")
        #expect(page.result.metadata.passes == 2)
        #expect(page.result.lines.allSatisfy { !$0.needsReview }, "gleiche Ergebnisse: nichts unsicher")
        #expect(page.result.warnings.isEmpty)
    }

    @Test("Mehrfacherkennung: abweichende Wörter sind unsicher mit Grund variesBetweenPasses")
    func multiPassVariation() async throws {
        let recognizer = CountingRecognizer { number, _, _ in
            number == 0 ? mockOutput(mockLine("Chlorophyll ist grüne Farbe")) : mockOutput(mockLine("Chlorophyll ist grune Farbe"))
        }
        let page = try await pipeline(recognizer, settings: PipelineSettings(multiPass: true)).digitizeImage(blankImage())
        let line = try #require(page.result.lines.first)
        #expect(line.text == "Chlorophyll ist grüne Farbe", "Text des ersten Durchlaufs bleibt")
        #expect(line.status == .uncertain)
        #expect(line.reviewReasons.contains(.variesBetweenPasses))
        let flagged = line.words.filter { $0.reviewReasons.contains(.variesBetweenPasses) }
        #expect(flagged.map(\.text) == ["grüne"])
        #expect(flagged.allSatisfy { $0.status == .uncertain })
        #expect(line.words.filter { !$0.needsReview }.count == 3)
        #expect(page.result.warnings.count == 1)
        #expect(page.result.warnings[0].contains("1 Wort"))
    }

    @Test("Mehrfacherkennung: ein Wort, das im zweiten Durchlauf fehlt, ist unsicher")
    func multiPassMissingWord() async throws {
        let recognizer = CountingRecognizer { number, _, _ in
            number == 0 ? mockOutput(mockLine("eins zwei drei")) : mockOutput(mockLine("eins zwei", wordWidth: 0.1))
        }
        let page = try await pipeline(recognizer, settings: PipelineSettings(multiPass: true)).digitizeImage(blankImage())
        let line = try #require(page.result.lines.first)
        #expect(line.words.filter(\.needsReview).map(\.text) == ["drei"])
    }

    @Test("Eine niedrige Konfidenz bleibt neben variesBetweenPasses erhalten")
    func multiPassKeepsLowConfidence() async throws {
        let recognizer = CountingRecognizer { number, _, _ in
            var line = mockLine("Wort")
            if number == 0 {
                line.words[0].status = .uncertain
                line.words[0].reviewReasons = [.lowConfidence]
                return mockOutput(line)
            }
            return mockOutput(mockLine("Wart"))
        }
        let page = try await pipeline(recognizer, settings: PipelineSettings(multiPass: true)).digitizeImage(blankImage())
        let word = try #require(page.result.lines.first?.words.first)
        #expect(word.reviewReasons == [.lowConfidence, .variesBetweenPasses])
    }

    @Test("Bild ohne Text: Warnung auf Deutsch, kein Absturz")
    func emptyImage() async throws {
        let page = try await pipeline(CountingRecognizer()).digitizeImage(blankImage())
        #expect(page.result.lines.isEmpty)
        #expect(page.result.warnings == ["Auf dem Bild wurde kein Text erkannt."])
        #expect(page.result.originalMarkdown.isEmpty)
    }

    @Test("Zeilen werden in Lesereihenfolge nummeriert und als Markdown ausgegeben")
    func readingOrderAndMarkdown() async throws {
        let recognizer = CountingRecognizer { _, _, _ in
            mockOutput(mockLine("unten", y: 0.5), mockLine("oben", y: 0.1))
        }
        let page = try await pipeline(recognizer).digitizeImage(blankImage())
        #expect(page.result.lines.map(\.text) == ["oben", "unten"])
        #expect(page.result.lines.map(\.order) == [0, 1])
        #expect(page.result.originalMarkdown.contains("oben"))
        #expect(page.result.originalMarkdown.range(of: "oben")!.lowerBound < page.result.originalMarkdown.range(of: "unten")!.lowerBound)
    }

    @Test("Herkunft: Erkanntes ist recognizer, auch wenn der Erkenner keine angibt")
    func originOfRecognizedLines() async throws {
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Fotosynthese ist wichtig")) }
        let page = try await pipeline(recognizer).digitizeImage(blankImage())
        #expect(page.result.lines.map(\.origin) == [.recognizer])
        #expect(!WordReview.isEmbedded(page.result.lines[0]))
    }

    @Test("Herkunft auf einer Goodnotes-Seite: Arbeitsblatt-Text pdfText, Textfeld freeText, Handschrift recognizer")
    func originOnGoodnotesPage() async throws {
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Notiz", y: 0.5)) }
        let data = try fixtureData(GoodnotesFixture.fotosyntheseEditable.url)
        let pages = try await pipeline(recognizer).digitizePDF(data: data).pages
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        let freeTexts = Set(truth.items(ofKind: .freeText).compactMap(\.text))
        let lines = pages.flatMap(\.result.lines)
        #expect(lines.allSatisfy { $0.origin != nil })
        let freeTextLines = lines.filter { freeTexts.contains($0.text) }
        #expect(!freeTextLines.isEmpty && freeTextLines.allSatisfy { $0.origin == .freeText })
        let title = try #require(pages[1].result.lines.first { $0.text == "Arbeitsblatt: Die Zelle" })
        let sentence = try #require(pages[1].result.lines.first { $0.text.hasPrefix("Der Zellkern") })
        #expect(title.origin == .pdfText && sentence.origin == .pdfText)
        let ink = lines.filter { $0.text == "Notiz" || $0.status == .illegible }
        #expect(!ink.isEmpty && ink.allSatisfy { $0.origin == .recognizer })
    }

    @Test("Kein PDF: Fehler notAPDF")
    func notAPDF() async throws {
        let pipeline = pipeline(CountingRecognizer())
        await #expect(throws: DigitizationError.notAPDF) {
            _ = try await pipeline.digitizePDF(data: Data("kein pdf".utf8))
        }
    }

    @Test("PDF ohne eingebetteten Text: Seite wird gerendert und erkannt, ein Aufruf je Seite")
    func scannedPDFIsRecognized() async throws {
        // The reduced PDF alone has no usable embedded text for recognition (SPEC: render and recognize like an image).
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        let recognizer = CountingRecognizer { number, _, _ in mockOutput(mockLine("Seite \(number)")) }
        let pages = try await pipeline(recognizer).digitizePDF(data: data).pages
        #expect(pages.count == 3)
        #expect(recognizer.callCount == 3)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
        for page in pages {
            #expect(page.result.metadata.method == .vision)
            #expect(page.result.metadata.passes == 1)
            #expect(abs(page.result.pageSize.width - 595.28) < 0.01)
            let image = try #require(page.imageData)
            #expect(Array(image.prefix(2)) == [0xFF, 0xD8])
        }
        // Rendered at the recognition scale (3 px per point).
        #expect(recognizer.calls.allSatisfy { $0.imageWidth == 1786 })
    }

    @Test("Mehrfacherkennung bei PDF-Seiten: zwei Aufrufe je Seite")
    func scannedPDFMultiPass() async throws {
        let data = try fixtureData(GoodnotesFixture.andereNotizReduced.url)
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Text hier")) }
        let pages = try await pipeline(recognizer, settings: PipelineSettings(multiPass: true)).digitizePDF(data: data).pages
        #expect(pages.count == 1)
        #expect(recognizer.callCount == 2)
        #expect(pages[0].result.metadata.passes == 2)
    }

    @Test("Fortschritt wird nach jeder Seite gemeldet")
    func progress() async throws {
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        let collected = ProgressCollector()
        _ = try await pipeline(CountingRecognizer()).digitizePDF(data: data) { done, total in collected.add(done, total) }
        #expect(collected.values == [[1, 3], [2, 3], [3, 3]])
    }
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Int]] = []
    var values: [[Int]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func add(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append([done, total])
    }
}
