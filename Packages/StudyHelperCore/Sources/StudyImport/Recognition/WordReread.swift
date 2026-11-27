import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Everything needed to suggest readings for one marked word of the word review (D-044, D-046).
public struct WordRereadRequest: Sendable {
    /// The original page: a PDF page (Goodnotes export, worksheet, scan) or a photo.
    public var background: DigitalPageInput.Background
    /// The line of the word (with the user's corrections so far).
    public var line: RecognizedLine
    /// Index of the word in the line (`ReviewToken.index` of `WordReview.tokens(of:)`).
    public var wordIndex: Int
    /// Every line of the page: neighbouring rows limit the crop, neighbouring words give the model its context.
    public var pageLines: [RecognizedLine]
    /// Subject terms ("Fachbegriffe"); passed to Vision as custom words and preferred in the ranking.
    public var terms: Set<String>
    public var spellChecker: any SpellChecking
    /// Optional reordering by a model (on-device): gets candidates (at most 6) and the words before and after the
    /// word, answers with an ordering. Only an ordering of the given candidates is accepted; anything else is
    /// ignored, and without an answer within about 2 seconds the consensus order stays. Called only when the readings
    /// leave a choice between known words (`WordCandidateRanking.rerankPositions`), otherwise not at all.
    public var rerank: (@Sendable (_ candidates: [String], _ before: String, _ after: String) async -> [String])?

    public init(
        background: DigitalPageInput.Background, line: RecognizedLine, wordIndex: Int, pageLines: [RecognizedLine],
        terms: Set<String> = [], spellChecker: any SpellChecking,
        rerank: (@Sendable (_ candidates: [String], _ before: String, _ after: String) async -> [String])? = nil
    ) {
        self.background = background
        self.line = line
        self.wordIndex = wordIndex
        self.pageLines = pageLines
        self.terms = terms
        self.spellChecker = spellChecker
        self.rerank = rerank
    }
}

/// Suggests readings for one marked word.
public protocol WordCandidateProviding: Sendable {
    /// Suggestions, best first, at most 8; never the written word itself.
    func candidates(for request: WordRereadRequest) async throws -> [WordCandidate]
}

/// Reads the word again from the original: renders only the ink of the word's row (Goodnotes strokes) or a crop of
/// the page or photo, reads the word crop and the line crop with Vision (language correction on with the subject
/// terms as custom words, and off), ranks the readings by consensus (`WordCandidateRanking`), adds the local
/// suggestions (terms, line alternatives, spell checker) with less weight and lets the optional model reorder the
/// best candidates.
///
/// Vision runs on a dedicated queue, never on the Swift concurrency pool, and is cancelled with the calling task.
/// Readings of a line crop are kept for the next words of the same line.
public struct VisionWordCandidateProvider: WordCandidateProviding {
    public static let maximumCount = 8
    /// Candidates the model may reorder.
    static let rerankCount = 6
    /// Seconds to wait for the model.
    static let defaultRerankTimeout = 2.0

    let sources: DigitalPageSources
    let reader: any WordImageReading
    let cache: WordReadingCache
    let rerankTimeout: Double

    /// - Parameter sources: opened originals to share with the digital page; nil creates a private one (the
    ///   provider instance keeps it, so keep the provider for the whole review of a document).
    public init(sources: DigitalPageSources? = nil) {
        self.init(sources: sources, reader: VisionWordImageReader())
    }

    init(sources: DigitalPageSources?, reader: any WordImageReading, rerankTimeout: Double = defaultRerankTimeout) {
        self.sources = sources ?? DigitalPageSources()
        self.reader = reader
        self.cache = WordReadingCache()
        self.rerankTimeout = rerankTimeout
    }

    public func candidates(for request: WordRereadRequest) async throws -> [WordCandidate] {
        let line = request.line
        let tokens = WordReview.tokens(of: line)
        guard tokens.indices.contains(request.wordIndex) else { return [] }
        let token = tokens[request.wordIndex]
        let written = token.core
        guard !written.isEmpty else { return [] }
        let pageLines = request.pageLines.filter { $0.id != line.id } + [line]
        let checker = request.spellChecker as? CachingSpellChecker ?? CachingSpellChecker(request.spellChecker)
        let terms = request.terms
        let customWords = terms.sorted()

        try Task.checkCancellation()
        let sources = self.sources
        let background = request.background
        let crops = try await WordRereadQueue.run {
            try WordCropRenderer.crops(
                background: background, sources: sources, token: token, line: line, pageLines: pageLines)
        }
        try Task.checkCancellation()

        let lineKey = WordReadingCache.lineKey(line: line, background: background, terms: customWords)
        async let wordOn = read(crops.word, languageCorrection: true, customWords: customWords, cacheKey: nil)
        async let wordOff = read(crops.word, languageCorrection: false, customWords: [], cacheKey: nil)
        async let lineOn = read(crops.line, languageCorrection: true, customWords: customWords, cacheKey: lineKey + "|on")
        async let lineOff = read(crops.line, languageCorrection: false, customWords: [], cacheKey: lineKey + "|off")
        let readings = try await (wordOn, wordOff, lineOn, lineOff)
        try Task.checkCancellation()

        let span = crops.wordSpan
        let vision: [WordCandidateRanking.VisionList] = [
            .init(candidates: WordCandidateRanking.wordCropCandidates(readings.0, wordSpan: span), weight: 1, crop: .word),
            .init(candidates: WordCandidateRanking.wordCropCandidates(readings.1, wordSpan: span), weight: 0.7, crop: .word),
            .init(candidates: WordCandidateRanking.lineCropCandidates(readings.2, line: line.text, wordIndex: token.index),
                  weight: 1, crop: .line),
            .init(candidates: WordCandidateRanking.lineCropCandidates(readings.3, line: line.text, wordIndex: token.index),
                  weight: 0.7, crop: .line),
        ]
        let local = WordCandidateRanking.LocalLists.of(
            line: line, wordIndex: token.index, checker: checker, terms: terms)
        var ranked = WordCandidateRanking.rank(
            written: written, vision: vision, local: local, checker: checker, terms: terms, limit: Self.maximumCount)

        // The model only decides real ties between words (it preferred non-words when offered everything).
        let positions = request.rerank == nil ? [] : WordCandidateRanking.rerankPositions(
            ranked, checker: checker, terms: terms, maximum: Self.rerankCount)
        if let rerank = request.rerank, !positions.isEmpty {
            let context = WordReview.context(of: token.index, in: line.id, lines: pageLines)
            let offered = positions.map { ranked[$0].text }
            if let order = await WordCandidateRanking.value(within: rerankTimeout, {
                await rerank(offered, context.before, context.after)
            }) {
                ranked = WordCandidateRanking.applyOrder(order, to: ranked, positions: positions)
            }
            try Task.checkCancellation()
        }
        return Array(ranked.prefix(Self.maximumCount))
    }

    private func read(
        _ image: CGImage?, languageCorrection: Bool, customWords: [String], cacheKey: String?
    ) async throws -> TextReading {
        guard let image else { return TextReading(observations: []) }
        if let cacheKey, let cached = cache.reading(for: cacheKey) { return cached }
        let reading = try await reader.read(image, languageCorrection: languageCorrection, customWords: customWords)
        if let cacheKey { cache.store(reading, for: cacheKey) }
        return reading
    }
}

// MARK: - Reading

/// Reads the text of an image region (Vision in the app, fakes in tests).
protocol WordImageReading: Sendable {
    func read(_ image: CGImage, languageCorrection: Bool, customWords: [String]) async throws -> TextReading
}

/// The dedicated queue of the word re-reading: Vision's synchronous `perform` and PDF parsing must not block (or
/// hang on) the Swift concurrency pool.
enum WordRereadQueue {
    static let queue = DispatchQueue(
        label: "StudyImport.WordReread", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Readings of line crops (several words of one line are often corrected one after the other).
final class WordReadingCache: @unchecked Sendable {
    static let capacity = 64
    private let lock = NSLock()
    private var readings: [String: TextReading] = [:]

    static func lineKey(line: RecognizedLine, background: DigitalPageInput.Background, terms: [String]) -> String {
        var hasher = Hasher()
        switch background {
        case .pdf(let data, let pageIndex, _):
            hasher.combine(data.count)
            hasher.combine(data.prefix(1024))
            hasher.combine(pageIndex)
        case .image(let data):
            hasher.combine(data.count)
            hasher.combine(data.prefix(1024))
        }
        hasher.combine(line.text)
        hasher.combine(line.rect)
        hasher.combine(terms)
        return "\(line.id.uuidString)|\(hasher.finalize())"
    }

    func reading(for key: String) -> TextReading? { lock.withLock { readings[key] } }

    func store(_ reading: TextReading, for key: String) {
        lock.withLock {
            if readings.count >= Self.capacity { readings.removeAll(keepingCapacity: true) }
            readings[key] = reading
        }
    }
}

// MARK: - Crops

/// The images Vision reads for one word.
struct WordCrops: @unchecked Sendable {
    /// The word with some margin (nil: nothing to read, e.g. the word lies outside the page).
    var word: CGImage?
    /// Horizontal range of the word in `word`, 0…1.
    var wordSpan: ClosedRange<Double>
    /// The word's line.
    var line: CGImage?
}

/// Renders the crops of a word: for editable Goodnotes pages only the pen strokes whose centre lies in the word's row
/// (neighbouring rows' ascenders and descenders stay out), otherwise a crop of the rendered page or photo limited to
/// the row band (`WordGeometry.bandRect`).
enum WordCropRenderer {
    /// Target height of a row in the crops, in pixels.
    static let rowPixels = 150.0
    /// Margins around the word (in row heights): horizontal, vertical.
    static let wordMargin = (x: 0.25, y: 0.25)
    static let lineMargin = (x: 0.3, y: 0.15)
    /// Raster crops (no strokes to pick): small vertical margin, the band already ends between the rows.
    static let rasterMarginY = 0.08
    static let maximumSide = 5800.0

    static func crops(
        background: DigitalPageInput.Background, sources: DigitalPageSources, token: ReviewToken,
        line: RecognizedLine, pageLines: [RecognizedLine]
    ) throws -> WordCrops {
        var pdf: OpenedPDF?
        var document: PDFDocument?
        if case .pdf(let data, _, _) = background {
            let opened = try sources.pdf(data)
            pdf = opened
            document = try opened.checkOut()
        }
        defer { if let pdf, let document { pdf.checkIn(document) } }
        let source = try DigitalPageSource.open(background, pdf: pdf, document: document)
        let size = source.size
        guard size.width > 0, size.height > 0 else { throw DigitalPageError.renderingFailed }

        let wordRect = token.rect.isEmpty ? line.rect : token.rect
        let lineRect = line.rect.isEmpty ? wordRect : line.rect

        if let page = source.goodnotesPage,
           let word = strokeCrop(page: page, rect: wordRect, margin: wordMargin, line: line, pageLines: pageLines) {
            let line = strokeCrop(page: page, rect: lineRect, margin: lineMargin, line: line, pageLines: pageLines)
            return WordCrops(word: word.image, wordSpan: span(of: wordRect, in: word.rect), line: line?.image)
        }

        // Raster: the page (with its annotations) or the photo, cut to the row band.
        let wordBand = WordGeometry.bandRect(for: wordRect, line: line, pageLines: pageLines)
        let lineBand = WordGeometry.bandRect(for: lineRect, line: line, pageLines: pageLines)
        let rowHeight = wordBand.height
        let wordCrop = expanded(wordBand, dx: wordMargin.x * rowHeight * size.height / size.width,
                                dy: rasterMarginY * rowHeight)
        let lineCrop = expanded(lineBand, dx: lineMargin.x * rowHeight * size.height / size.width,
                                dy: rasterMarginY * rowHeight)
        let scale = scaleFor(rowHeight: rowHeight * size.height)
        if let page = source.pdfPage {
            let word = renderPDF(page: page, size: size, crop: wordCrop, scale: scale)
            let line = renderPDF(page: page, size: size, crop: lineCrop, scale: scale)
            return WordCrops(word: word, wordSpan: span(of: wordRect, in: wordCrop), line: line)
        }
        if let photo = source.photo {
            let word = cropImage(photo, crop: wordCrop, scale: scale)
            let line = cropImage(photo, crop: lineCrop, scale: scale)
            return WordCrops(word: word, wordSpan: span(of: wordRect, in: wordCrop), line: line)
        }
        throw DigitalPageError.renderingFailed
    }

    /// Pixels per point (or per photo pixel) for a row of `rowHeight` points.
    static func scaleFor(rowHeight: Double) -> Double {
        min(10, max(1, rowPixels / max(rowHeight, 1)))
    }

    static func expanded(_ rect: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        let x0 = max(0, rect.minX - dx), y0 = max(0, rect.minY - dy)
        let x1 = min(1, rect.maxX + dx), y1 = min(1, rect.maxY + dy)
        guard x1 > x0, y1 > y0 else { return .zero }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Horizontal range of `rect` inside `crop`, 0…1.
    static func span(of rect: NormalizedRect, in crop: NormalizedRect) -> ClosedRange<Double> {
        guard crop.width > 0 else { return 0...1 }
        let start = min(1, max(0, (rect.minX - crop.minX) / crop.width))
        let end = min(1, max(start, (rect.maxX - crop.minX) / crop.width))
        return start...end
    }

    /// Indexes of the pen strokes (no highlighters) touching `crop` whose vertical centre lies in the stroke band of
    /// the row of `rect` (`WordGeometry.strokeBand`).
    static func strokeIndices(
        page: GoodnotesPage, rect: NormalizedRect, crop: NormalizedRect, line: RecognizedLine,
        pageLines: [RecognizedLine]
    ) -> [Int] {
        let band = WordGeometry.strokeBand(
            centre: rect.midY, height: rect.height, xRange: rect.minX...rect.maxX, line: line, pageLines: pageLines)
        let highlighters = page.highlighterFlags
        var indices: [Int] = []
        for (index, stroke) in page.strokes.enumerated() where !highlighters[index] && !stroke.points.isEmpty {
            let box = stroke.boundingBox(pageSize: page.size)
            guard box.maxX >= crop.minX, box.minX <= crop.maxX, box.maxY >= crop.minY, box.minY <= crop.maxY,
                  band.contains(box.midY) else { continue }
            indices.append(index)
        }
        return indices
    }

    /// The pen strokes of the row of `rect` (`strokeIndices`), black on white. Nil if no stroke qualifies (text in
    /// an image, a stamp …).
    static func strokeCrop(
        page: GoodnotesPage, rect: NormalizedRect, margin: (x: Double, y: Double), line: RecognizedLine,
        pageLines: [RecognizedLine]
    ) -> (image: CGImage, rect: NormalizedRect)? {
        guard page.size.width > 0, page.size.height > 0, !rect.isEmpty else { return nil }
        let height = rect.height
        let crop = expanded(rect, dx: margin.x * height * page.size.height / page.size.width, dy: margin.y * height)
        guard !crop.isEmpty else { return nil }
        let indices = strokeIndices(page: page, rect: rect, crop: crop, line: line, pageLines: pageLines)
        guard !indices.isEmpty else { return nil }
        var scale = scaleFor(rowHeight: height * page.size.height)
        scale = min(scale, maximumSide / max(crop.width * page.size.width, crop.height * page.size.height, 1))
        return InkLayerRendering.renderStrokes(page: page, indices: indices, crop: crop, scale: scale)
    }

    /// A region of a PDF page (displayed orientation, annotations included) in gray.
    static func renderPDF(page: PDFPage, size: PageSize, crop: NormalizedRect, scale: Double) -> CGImage? {
        guard !crop.isEmpty else { return nil }
        let scale = min(scale, maximumSide / max(crop.width * size.width, crop.height * size.height, 1))
        let width = Int((crop.width * size.width * scale).rounded(.up))
        let height = Int((crop.height * size.height * scale).rounded(.up))
        guard width > 2, height > 2, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        let coveredHeight = Double(height) / scale
        context.translateBy(x: -crop.x * size.width, y: -(size.height - crop.y * size.height - coveredHeight))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// A region of an upright photo, enlarged so that a row is about `rowPixels` high.
    static func cropImage(_ image: CGImage, crop: NormalizedRect, scale: Double) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h).integral
        guard rect.width > 2, rect.height > 2, let cut = image.cropping(to: rect) else { return nil }
        let factor = min(4, scale, maximumSide / max(rect.width, rect.height))
        guard factor > 1.05 else { return cut }
        return PageRenderer.scaled(cut, by: factor) ?? cut
    }
}
