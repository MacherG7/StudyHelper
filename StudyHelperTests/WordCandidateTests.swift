import Foundation
import StudyCore
import StudyData
import StudyImport
import SwiftData
import Testing
import UIKit
@testable import StudyHelper

/// Provider that counts calls and the most that ran at once; can be held at a gate.
private final class FakeProvider: WordCandidateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var running = 0
    private var peak = 0
    private let delay: Duration
    private let gate: Gate?

    init(delay: Duration = .milliseconds(20), gate: Gate? = nil) {
        self.delay = delay
        self.gate = gate
    }

    var callCount: Int { lock.withLock { calls } }
    var maxConcurrent: Int { lock.withLock { peak } }

    func candidates(for request: WordRereadRequest) async throws -> [WordCandidate] {
        lock.withLock {
            calls += 1
            running += 1
            peak = max(peak, running)
        }
        defer { lock.withLock { running -= 1 } }
        if let gate { await gate.wait() } else { try await Task.sleep(for: delay) }
        let word = request.line.text
        return [WordCandidate(text: word + "x", score: 1, sources: [.vision])]
    }
}

@Suite("Wortvorschläge im Hintergrund, Wortbild und Fachbegriff-Hinweis")
@MainActor
struct WordCandidateTests {
    // MARK: Helpers

    private func job(_ index: Int, digitization: UUID = UUID()) -> WordCandidatePrefetcher.Job {
        let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let line = RecognizedLine(
            text: "Wort\(index)", rect: rect, words: [RecognizedWord(text: "Wort\(index)", rect: rect)], order: index)
        let request = WordRereadRequest(
            background: .image(data: Data()), line: line, wordIndex: 0, pageLines: [line], terms: [],
            spellChecker: UITestSpellChecker(unknown: []), rerank: nil)
        return .init(
            key: WordKey(digitizationID: digitization, lineID: line.id, wordIndex: 0, text: line.text), request: request)
    }

    // MARK: Candidate cache and prefetcher

    @Test("Der beste Vorschlag ist der erste, der vom geschriebenen Wort abweicht")
    func bestGuess() {
        let cache = WordCandidateCache()
        let key = WordKey(digitizationID: UUID(), lineID: UUID(), wordIndex: 2, text: "„Sistem,")
        #expect(cache.candidates(for: key) == nil && cache.bestGuess(for: key) == nil)
        cache.store([], for: key)
        #expect(cache.candidates(for: key)?.isEmpty == true && cache.bestGuess(for: key) == nil)
        cache.store([
            WordCandidate(text: "Sistem", score: 1, sources: [.vision]),
            WordCandidate(text: "System", score: 0.9, sources: [.spelling]),
        ], for: key)
        #expect(cache.bestGuess(for: key) == "System", "das Wort selbst („Sistem“) ist kein Vorschlag")
    }

    @Test("Der Zwischenspeicher ist begrenzt")
    func cacheIsBounded() {
        let cache = WordCandidateCache(limit: 10)
        for index in 0..<25 {
            cache.store([], for: WordKey(digitizationID: UUID(), lineID: UUID(), wordIndex: index, text: "x"))
        }
        #expect(cache.count <= 10)
    }

    @Test("Hintergrundberechnung: höchstens zwei gleichzeitig, jedes Wort einmal, Ergebnis im Zwischenspeicher")
    func prefetchRunsTwoAtATime() async {
        let cache = WordCandidateCache()
        let provider = FakeProvider()
        let prefetcher = WordCandidatePrefetcher(cache: cache, provider: provider, maxConcurrent: 2)
        let jobs = (0..<7).map { job($0) }
        prefetcher.start(jobs)
        await prefetcher.waitUntilIdle()
        #expect(provider.callCount == 7)
        #expect(provider.maxConcurrent == 2)
        #expect(jobs.allSatisfy { cache.bestGuess(for: $0.key) == $0.request.line.text + "x" })

        // Cached words are skipped when the page is shown again.
        prefetcher.start(jobs)
        await prefetcher.waitUntilIdle()
        #expect(provider.callCount == 7, "nichts wird ein zweites Mal gelesen")
        #expect(!prefetcher.isRunning)
    }

    @Test("Verlassen der Seite bricht die Berechnung ab; unfertige Wörter werden nicht gespeichert")
    func cancelStopsAndStoresNothingUnfinished() async {
        let cache = WordCandidateCache()
        let gate = Gate()
        let provider = FakeProvider(gate: gate)
        let prefetcher = WordCandidatePrefetcher(cache: cache, provider: provider, maxConcurrent: 2)
        let jobs = (0..<6).map { job($0) }
        prefetcher.start(jobs)
        #expect(await waitUntil { provider.callCount == 2 })
        prefetcher.cancel()
        #expect(!prefetcher.isRunning)
        gate.open()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.callCount == 2, "es werden keine weiteren Wörter begonnen")
        #expect(cache.count == 0, "die abgebrochenen Wörter sind nicht gespeichert")

        // Shown again: everything is computed.
        let again = WordCandidatePrefetcher(cache: cache, provider: FakeProvider(), maxConcurrent: 2)
        again.start(jobs)
        await again.waitUntilIdle()
        #expect(cache.count == 6)
    }

    @Test("Ein geändertes Wort (anderer Text) wird neu gelesen")
    func changedTextIsAnotherKey() async {
        let cache = WordCandidateCache()
        let provider = FakeProvider()
        let prefetcher = WordCandidatePrefetcher(cache: cache, provider: provider)
        let original = job(1)
        prefetcher.start([original])
        await prefetcher.waitUntilIdle()
        var changed = original
        changed.key.text = "Anders"
        prefetcher.start([original, changed])
        await prefetcher.waitUntilIdle()
        #expect(provider.callCount == 2)
    }

    // MARK: Confirmed readings and repeated words (D-047)

    @Test("Bestätigte Lesung: gemerkt, kein Schnellvorschlag; die Zähler-Revision steigt nur bei neuer Bestätigung")
    func confirmedReadingInCache() {
        let cache = WordCandidateCache()
        let key = WordKey(digitizationID: UUID(), lineID: UUID(), wordIndex: 0, text: "Lithosphäre,")
        let candidates = [WordCandidate(text: "Litosphäre", score: 1, sources: [.vision], readings: 2)]
        #expect(!cache.isConfirmed(key))
        cache.store(WordRereadResult(candidates: candidates, readingConfirmed: true), for: key)
        #expect(cache.isConfirmed(key) && cache.result(for: key)?.readingConfirmed == true)
        #expect(cache.bestGuess(for: key) == nil, "kein „→ Wort?“ für ein bestätigtes Wort")
        #expect(cache.confirmationRevision == 1)
        cache.store(WordRereadResult(candidates: candidates, readingConfirmed: true), for: key)
        cache.store([], for: WordKey(digitizationID: UUID(), lineID: UUID(), wordIndex: 1, text: "x"))
        #expect(cache.confirmationRevision == 1, "dieselbe Bestätigung und neue Vorschläge ändern die Zähler nicht")
        // A case-only variant is no quick fix.
        let other = WordKey(digitizationID: UUID(), lineID: UUID(), wordIndex: 0, text: "lauch")
        cache.store([WordCandidate(text: "Lauch", score: 1, sources: [.vision]),
                     WordCandidate(text: "auch", score: 0.8, sources: [.vision])], for: other)
        #expect(cache.bestGuess(for: other) == "auch")
    }

    private final class ConfirmingProvider: WordCandidateProviding, @unchecked Sendable {
        func candidates(for request: WordRereadRequest) async throws -> [WordCandidate] { [] }
        func reread(for request: WordRereadRequest) async throws -> WordRereadResult {
            WordRereadResult(candidates: [], readingConfirmed: request.line.text.hasPrefix("Wort1"))
        }
    }

    @Test("Hintergrundberechnung speichert, ob die Lesung bestätigt ist")
    func prefetchStoresConfirmation() async {
        let cache = WordCandidateCache()
        let prefetcher = WordCandidatePrefetcher(cache: cache, provider: ConfirmingProvider())
        let jobs = [job(1), job(2)]
        prefetcher.start(jobs)
        await prefetcher.waitUntilIdle()
        #expect(cache.isConfirmed(jobs[0].key) && !cache.isConfirmed(jobs[1].key))
        #expect(cache.result(for: jobs[1].key) != nil)
    }

    private func page(_ texts: [String]) -> [RecognizedLine] {
        texts.enumerated().map { order, text in
            let rect = NormalizedRect(x: 0.1, y: 0.05 * Double(order + 1), width: 0.8, height: 0.04)
            let words = WordTokenizer.tokens(in: text).enumerated().map { i, token in
                RecognizedWord(text: token.original, rect: NormalizedRect(
                    x: 0.1 + 0.15 * Double(i), y: rect.y, width: 0.14, height: rect.height))
            }
            return RecognizedLine(text: text, rect: rect, words: words, order: order, origin: .recognizer)
        }
    }

    @Test("Bestätigte Wörter zählen nicht als offen; Wörter ohne Bestätigung bleiben markiert")
    func confirmedWordsAreNotOpen() {
        let checker = UITestSpellChecker(unknown: ["lithosphäre", "klimg"])
        let lines = page(["Die Lithosphäre und das Klimg"])
        let review = PageWordReview(lines: lines, method: nil, terms: [], checker: checker)
        #expect(review.openWords == 2)
        let digitization = UUID()
        let confirmed = WordKey(digitizationID: digitization, lineID: lines[0].id, wordIndex: 1, text: "Lithosphäre")
        let shown = review.excludingConfirmed(digitizationID: digitization) { $0 == confirmed }
        #expect(shown.openWords == 1)
        #expect(shown.markedTokens(of: lines[0].id).map(\.core) == ["Klimg"])
        // Another digitization (new recognition) or another text: still open.
        #expect(review.excludingConfirmed(digitizationID: UUID()) { $0 == confirmed }.openWords == 2)

        // The background summary leaves confirmed words out too.
        var input = PageReviewInput()
        input.digitizationID = digitization
        input.lines = lines
        input.state = .done
        let store = ConfirmedReadings()
        #expect(PageSummary(input: input, checker: checker, confirmed: store).openWords == 2)
        store.insert(confirmed)
        #expect(PageSummary(input: input, checker: checker, confirmed: store).openWords == 1)
    }

    @Test("Wörter anderer Seiten des Fachs: je Seite gemerkt, ohne die eigene Seite; Revision nur bei Änderung")
    func subjectWords() {
        let index = SubjectWords()
        let subject = UUID(), pageA = UUID(), pageB = UUID()
        index.update([
            .init(subjectID: subject, sourceID: pageA, words: ["aralsee-syndrom", "lithosphäre"]),
            .init(subjectID: subject, sourceID: pageB, words: ["eritrea"]),
            .init(subjectID: UUID(), sourceID: UUID(), words: ["fremd"]),
        ])
        #expect(index.revision == 1)
        #expect(index.otherPageWords(subjectID: subject, excluding: pageB) == ["aralsee-syndrom", "lithosphäre"])
        #expect(index.otherPageWords(subjectID: subject, excluding: pageA) == ["eritrea"])
        #expect(index.otherPageWords(subjectID: nil, excluding: pageA).isEmpty)
        index.update([.init(subjectID: subject, sourceID: pageB, words: ["eritrea"])])
        #expect(index.revision == 1, "gleiche Wörter: keine neue Runde")
        // A new recognition of page A replaces its words.
        index.update([.init(subjectID: subject, sourceID: pageA, words: ["pedosphäre"])])
        #expect(index.revision == 2)
        #expect(index.otherPageWords(subjectID: subject, excluding: pageB) == ["pedosphäre"])

        // A word of another page counts as intended; the memo key follows those words.
        let checker = UITestSpellChecker(unknown: ["eritrea"])
        let lines = page(["Länder wie Eritrea"])
        #expect(PageWordReview(lines: lines, method: nil, terms: [], checker: checker).openWords == 1)
        #expect(PageWordReview(lines: lines, method: nil, terms: [], checker: checker, otherPageWords: ["eritrea"])
            .openWords == 0)
        let id = UUID()
        #expect(PageWordReviewCache.Key(digitizationID: id, lines: lines, terms: [], method: nil, checker: checker)
                != PageWordReviewCache.Key(
                    digitizationID: id, lines: lines, terms: [], method: nil, checker: checker,
                    otherPageWords: ["eritrea"]))
    }

    // MARK: Word picture

    @Test("Wortbild: Rand um das Wort, an der Seite beschnitten")
    func cropRegion() {
        let band = NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.04)
        let region = WordCrop.region(band: band, pageAspect: 0.75)
        #expect(region.minX < band.minX && region.minY < band.minY)
        #expect(region.maxX > band.maxX && region.maxY > band.maxY)
        #expect(abs((band.minY - region.minY) - 0.04 * WordCrop.marginFactor) < 1e-9)
        let corner = WordCrop.region(band: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.05), pageAspect: 0.75)
        #expect(corner.minX == 0 && corner.minY == 0)
    }

    private func photo(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: Double(width) * 0.3, y: Double(height) * 0.4, width: Double(width) * 0.2, height: Double(height) * 0.04))
        }
        return try #require(image.pngData())
    }

    /// Fraction of dark pixels in the middle of the image.
    private func darkShare(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = 40, height = 20
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] < 100 { dark += 1 }
        return Double(dark) / Double(width * height)
    }

    @Test("Wortbild aus einem Foto: mindestens 1000 Pixel breit, scharf hochgerechnet, zeigt das Wort")
    func photoCropIsEnlarged() throws {
        let data = try photo(width: 2000, height: 2700)
        let band = NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.04)
        let image = try #require(WordCrop.photoCrop(data: data, band: band))
        let pixels = (image.cgImage?.width ?? 0)
        #expect(pixels >= WordCrop.targetPixelWidth - 2, "Breite: \(pixels)")
        #expect(darkShare(image) > 0.3, "das Wort (schwarzer Balken) ist im Bild")
        // A crop that is large enough is not enlarged.
        let large = try photo(width: 6000, height: 8100)
        let big = try #require(WordCrop.photoCrop(data: large, band: band))
        #expect((big.cgImage?.width ?? 0) > 1_000 && (big.cgImage?.width ?? 0) < 1_700)
    }

    @Test("Wortbild aus einer PDF-Seite wird neu gezeichnet statt hochgerechnet")
    func pdfCropIsRendered() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            // Same place as the photo's bar: x 30–50 %, y 40–44 % of the page from the top.
            context.fill(CGRect(x: 180, y: 320, width: 120, height: 32))
        }
        let band = NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.04)
        let image = try #require(WordCrop.pdfCrop(data: data, pageIndex: 0, band: band))
        #expect((image.cgImage?.width ?? 0) >= WordCrop.targetPixelWidth - 2)
        #expect(darkShare(image) > 0.3)
        // The bar is cut out in the right place: nothing else of the page is in the crop.
        #expect(darkShare(image) < 0.9)
        #expect(WordCrop.pdfCrop(data: data, pageIndex: 3, band: band) == nil)
    }

    // MARK: Term banner

    @Test("Fachbegriff-Hinweis: ausblenden gilt je Import")
    func termBannerDismissalPerImport() throws {
        let defaults = try #require(UserDefaults(suiteName: "StudyHelperTests-Terms-\(UUID().uuidString)"))
        let first = UUID(), second = UUID()
        #expect(!TermSuggestionPreference.isDismissed(first, defaults: defaults))
        TermSuggestionPreference.dismiss(first, defaults: defaults)
        #expect(TermSuggestionPreference.isDismissed(first, defaults: defaults))
        #expect(!TermSuggestionPreference.isDismissed(second, defaults: defaults))
        TermSuggestionPreference.reset(first, defaults: defaults)
        #expect(!TermSuggestionPreference.isDismissed(first, defaults: defaults))
    }

    @Test("Regel der UI-Tests für Fachbegriffe")
    func uiTestTermRule() {
        let rect = NormalizedRect(x: 0, y: 0, width: 1, height: 0.1)
        let line = RecognizedLine(text: "Ort: Chloroplasten und Blattfarbstoff, Chloroplasten, Haus", rect: rect, order: 0)
        let checker = UITestSpellChecker(unknown: ["chloroplasten", "blattfarbstoff", "haus"])
        let terms = AppTermSuggestions.uiTestProvider([line], checker, ["blattfarbstoff"])
        #expect(terms == ["Chloroplasten"], "kleine Wörter, bekannte Begriffe und Doppelte fehlen: \(terms)")
    }

    // MARK: Background counts

    /// A word of letters only that occurs nowhere else (repeated words count as intended, D-047).
    private static func uniqueWord(_ number: Int) -> String {
        var n = number, letters = ""
        repeat {
            letters.append(Character(UnicodeScalar(UInt8(97 + n % 26))))
            n /= 26
        } while n > 0
        return "Zwerg" + letters
    }

    private func subjectWithPages(_ pages: Int) throws -> (StudyRepository, Subject) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        let subject = try repository.createSubject(name: "Bio")
        let batch = try repository.createBatch(
            in: subject, kind: .pdf, originalFileName: "x.pdf",
            pages: (0..<pages).map { _ in SourceInput(imageData: Data([1]), pageSize: PageSize(width: 600, height: 800)) })
        for (page, source) in batch.sortedSources.enumerated() {
            let lines = (0..<20).map { order in
                let texts = (0..<3).map { Self.uniqueWord(page * 100 + order * 3 + $0) }
                return RecognizedLine(
                    text: texts.joined(separator: " "), rect: NormalizedRect(x: 0.1, y: 0.04 * Double(order), width: 0.5, height: 0.03),
                    words: texts.enumerated().map {
                        RecognizedWord(text: $1, rect: NormalizedRect(x: 0.1 + 0.1 * Double($0), y: 0.04 * Double(order), width: 0.09, height: 0.03))
                    }, order: order, origin: .recognizer)
            }
            let result = DigitizationResult(
                lines: lines, highlights: [],
                metadata: RecognitionMetadata(method: .vision, engineVersion: "x", osVersion: "x", deviceModel: "x"),
                originalMarkdown: OriginalTextMarkdown.build(lines: lines, highlights: []),
                pageSize: PageSize(width: 600, height: 800))
            _ = try repository.saveDigitization(result, for: source)
        }
        return (repository, subject)
    }

    /// Every lookup takes a moment, like the system dictionary does for unknown words.
    private final class SlowChecker: SpellChecking, @unchecked Sendable {
        func isKnown(_ word: String) -> Bool {
            Thread.sleep(forTimeInterval: 0.0005)
            return false
        }
        func guesses(for word: String) -> [String] { [] }
    }

    @Test("Die Zahlen eines Fachs entstehen im Hintergrund: der erste Aufbau wartet nicht, die Hauptaufgabe bleibt frei")
    func countsAreComputedOffTheMainActor() async throws {
        PageWordReviewCache.shared.removeAll()
        let (repository, subject) = try subjectWithPages(17)
        defer { withExtendedLifetime(repository) {} }
        let loader = PageSummaryLoader()
        #expect(loader.pages == nil, "vor dem Start gibt es keine Zahlen: die Ansicht zeigt einen Platzhalter")

        // A ticker on the main actor: it keeps running while the counts are computed.
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let start = ContinuousClock.now
        let checker = SlowChecker()
        let run = Task { await loader.run(sources: { subject.imports.flatMap(\.sources) }, checker: checker) }
        #expect(loader.pages == nil, "run kehrt nicht synchron mit Ergebnissen zurück")
        #expect(await waitUntil(timeout: .seconds(30)) { loader.pages != nil })
        let elapsed = ContinuousClock.now - start
        ticker.cancel()
        run.cancel()

        let pages = try #require(loader.pages)
        #expect(pages.count == 17)
        #expect(pages.allSatisfy { $0.open == 60 }, "jedes unbekannte Wort ist offen: \(pages.map(\.open))")
        // The main actor was free for most of the time: with a blocked main actor the ticker would stand still.
        #expect(elapsed > .milliseconds(100), "die Berechnung dauert (langsame Prüfung)")
        let expectedTicks = Int(elapsed / .milliseconds(5)) / 4
        #expect(ticks >= expectedTicks, "Hauptaufgabe war frei: \(ticks) Takte in \(elapsed), erwartet ≥ \(expectedTicks)")
        // The pages are in the shared memo now: opening one does not compute it again.
        #expect(PageWordReviewCache.shared.count >= 17)
    }

    @Test("Eine Änderung (neuer Fachbegriff) startet eine neue Berechnung")
    func countsFollowChanges() async throws {
        PageWordReviewCache.shared.removeAll()
        let (repository, subject) = try subjectWithPages(2)
        defer { withExtendedLifetime(repository) {} }
        let loader = PageSummaryLoader()
        let checker = SlowChecker()
        let run = Task { await loader.run(sources: { subject.imports.flatMap(\.sources) }, checker: checker) }
        #expect(await waitUntil(timeout: .seconds(20)) { loader.rounds >= 1 })
        // The order of a batch's sources is not fixed: compare the total of both pages.
        func total() -> Int { loader.pages?.reduce(0) { $0 + $1.open } ?? 120 }
        #expect(total() == 120)

        try repository.addConfirmedTerm(Self.uniqueWord(0), to: subject)
        #expect(await waitUntil(timeout: .seconds(20)) { total() < 120 })
        #expect(total() == 119, "das Wort gilt als Fachbegriff: eines weniger")

        run.cancel()
        _ = await run.value
    }

    @Test("Abbrechen beendet die Berechnung")
    func loaderStopsWhenCancelled() async throws {
        let (repository, subject) = try subjectWithPages(1)
        defer { withExtendedLifetime(repository) {} }
        let loader = PageSummaryLoader()
        let run = Task { await loader.run(sources: { subject.imports.flatMap(\.sources) }, checker: SlowChecker()) }
        run.cancel()
        _ = await run.value
        #expect(loader.rounds <= 1)
    }

    @Test("Summen aus den Seitenzahlen: Fach und Import")
    func totalsFromPages() throws {
        let (repository, subject) = try subjectWithPages(3)
        defer { withExtendedLifetime(repository) {} }
        let batch = try #require(subject.imports.first)
        let reviewed = [
            PageSummary(open: 2, openWords: 1, illegible: 1), PageSummary(open: 3, openWords: 3, illegible: 0),
            PageSummary(open: 0, openWords: 0, illegible: 0, unreadable: true),
        ]
        let subjectSummary = SubjectSummary(subject, reviewed: reviewed)
        #expect(subjectSummary.imports == 1 && subjectSummary.open == 5 && subjectSummary.unreadablePages == 1)
        let batchSummary = BatchSummary(batch, reviewed: reviewed)
        #expect(batchSummary.pages == 3 && batchSummary.openWords == 4 && batchSummary.illegible == 1)
        // Without counts (still computing) everything cheap is exact and the open counts are zero.
        let waiting = BatchSummary(batch, reviewed: [])
        #expect(waiting.pages == 3 && waiting.open == 0)
    }
}

private extension PageSummary {
    init(open: Int, openWords: Int, illegible: Int, unreadable: Bool = false) {
        self.init()
        self.open = open
        self.openWords = openWords
        self.illegible = illegible
        self.unreadable = unreadable
    }
}
