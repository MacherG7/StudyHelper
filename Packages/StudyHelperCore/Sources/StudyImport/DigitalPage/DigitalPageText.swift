import CoreGraphics
import CoreText
import Foundation
import StudyCore

/// A piece of text placed on the digital page: one word (its own box) or a whole line (the line box).
struct DigitalTextRun {
    struct Token {
        var text: String
        var color: StudyColor
        var bold: Bool
        /// The word should be checked by the user (drawn with a dotted underline in text mode).
        var needsReview: Bool
        /// False for an arrow symbol that a shape arrow (stamp) on the page already shows: it stays in the invisible
        /// text layer but is not drawn a second time in text mode.
        var drawsVisibly: Bool
    }

    /// Tokens, joined with single spaces.
    var tokens: [Token]
    /// Horizontal extent from the word (or line) box, vertical extent from the line box; displayed page points,
    /// origin bottom-left.
    var rect: CGRect
    /// A space after the run (between the words of a line), so that text extraction separates the words.
    var trailingSpace: Bool
    /// The line the run belongs to (runs of one line are laid out together in text mode).
    var lineID: UUID
    /// The line box in displayed page points, origin bottom-left.
    var lineRect: CGRect
    /// The run is the whole line in the line box (the words no longer match the word boxes).
    var isWholeLine: Bool
}

/// Where and how large a run is drawn visibly (text mode).
struct VisibleRunLayout: Equatable {
    /// Left end of the baseline (x = the box's minX), displayed page points.
    var origin: CGPoint
    var fontSize: Double
    /// Horizontal scaling of the glyphs.
    var horizontalScale: Double
    /// Drawn width (natural width at `fontSize` × `horizontalScale`).
    var width: Double
}

/// Placement and drawing of the stored text (invisible text layer and the visible text of the text mode).
enum DigitalPageText {
    static let arrowSymbols: Set<String> = ["→", "←", "↔", "↑", "↓", "↕", "↗", "↘", "↙", "↖"]
    /// Share of the line height filled by the font's ascent + descent.
    static let heightFill = 0.95
    /// Invisible text layer: horizontal scaling limits; text narrower than its box below `minimumScale` gets a
    /// smaller font instead.
    static let minimumScale = 0.5
    static let maximumScale = 2.0
    /// Visible text (text mode): horizontal scaling stays close to natural, so that coarse word boxes do not stretch
    /// or squash the words.
    static let visibleMinimumScale = 0.85
    static let visibleMaximumScale = 1.1
    /// Visible text: a word ends at least this many space widths before the next word starts.
    static let visibleGap = 0.6
    /// Visible text: a whole-line run may be this much wider than the line box.
    static let wholeLineOverflow = 1.1
    /// Visible text: the last word of a line may reach this many line heights beyond its box and the line box.
    static let lastWordOverflow = 1.0
    /// Visible text: a line is set at least this share of the size from its height before single words are forced
    /// smaller.
    static let minimumLineFactor = 0.6
    static let regularFont = "Helvetica"
    static let boldFont = "Helvetica-Bold"

    /// True if the line has text worth placing: not empty, and not an illegible spot (unless the user typed it).
    static func hasText(_ line: RecognizedLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (line.status != .illegible || line.isUserCorrected)
    }

    // MARK: Placement

    /// Runs for `lines` in reading order.
    /// - Parameters:
    ///   - highlights: bold highlights make their words bold.
    ///   - arrows: shape arrows (stamps) of the page; arrow symbols that stand for them are not drawn visibly.
    ///   - size: displayed page size in points (or pixels for photos).
    static func runs(
        for lines: [RecognizedLine], highlights: [RecognizedHighlight], arrows: [ShapeArrows.Arrow], size: PageSize
    ) -> [DigitalTextRun] {
        var bold: [UUID: Set<Int>] = [:]
        for highlight in highlights where highlight.kind == .bold {
            for word in highlight.words { bold[word.lineID, default: []].insert(word.wordIndex) }
        }
        var result: [DigitalTextRun] = []
        for line in lines.sorted(by: { $0.order < $1.order }) where hasText(line) && !line.rect.isEmpty {
            result += runs(for: line, bold: bold[line.id] ?? [], arrows: arrows, size: size)
        }
        return result
    }

    static func runs(for line: RecognizedLine, bold: Set<Int>, arrows: [ShapeArrows.Arrow], size: PageSize) -> [DigitalTextRun] {
        let pieces = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return [] }
        let words = line.words
        let lineColor = line.color ?? .black
        // Shape arrows sitting in this line's row (they were inserted into the text as symbols, D-025).
        var rowArrows = arrows.filter { arrow in
            arrow.rect.midY >= line.rect.minY && arrow.rect.midY <= line.rect.maxY
                && arrow.rect.height <= ShapeArrows.maximumHeight * max(line.rect.height, 0.0001)
        }.sorted { $0.rect.x < $1.rect.x }

        let lineBox: CGRect = {
            let l = line.rect.toBottomLeft(spaceWidth: size.width, spaceHeight: size.height)
            return CGRect(x: l.x, y: l.y, width: l.width, height: l.height)
        }()
        func box(_ r: NormalizedRect) -> CGRect {
            CGRect(x: r.x * size.width, y: lineBox.minY, width: r.width * size.width, height: lineBox.height)
        }
        func run(_ tokens: [DigitalTextRun.Token], _ rect: CGRect, trailingSpace: Bool, wholeLine: Bool = false) -> DigitalTextRun {
            DigitalTextRun(
                tokens: tokens, rect: rect, trailingSpace: trailingSpace, lineID: line.id, lineRect: lineBox,
                isWholeLine: wholeLine)
        }
        func wordToken(_ text: String, word index: Int?) -> DigitalTextRun.Token {
            guard let index, index < words.count else {
                return DigitalTextRun.Token(
                    text: text, color: lineColor, bold: false,
                    needsReview: !line.isUserCorrected && line.status != .confident, drawsVisibly: true)
            }
            let word = words[index]
            return DigitalTextRun.Token(
                text: text, color: word.color ?? lineColor, bold: bold.contains(index),
                needsReview: !line.isUserCorrected && word.needsReview, drawsVisibly: true)
        }
        /// Takes the leftmost row arrow with this symbol (nil if there is none).
        func takeArrow(_ symbol: String, near x: Double? = nil) -> ShapeArrows.Arrow? {
            let matching = rowArrows.indices.filter { rowArrows[$0].symbol == symbol }
            guard let first = matching.first else { return nil }
            let chosen = x.map { x in matching.min { abs(rowArrows[$0].rect.midX - x) < abs(rowArrows[$1].rect.midX - x) }! } ?? first
            return rowArrows.remove(at: chosen)
        }

        let wordsUsable = !words.isEmpty && words.allSatisfy { !$0.rect.isEmpty }

        // A. One token per word: each token at its word box (also after a correction that kept the word count).
        if wordsUsable, pieces.count == words.count {
            return pieces.enumerated().map { index, text in
                var token = wordToken(text, word: index)
                if arrowSymbols.contains(text), takeArrow(text, near: words[index].rect.midX).map({
                    $0.rect.intersection(words[index].rect.insetBy(dx: -0.002, dy: -0.002)).area > 0
                }) == true {
                    token.drawsVisibly = false
                }
                return run([token], box(words[index].rect), trailingSpace: index < pieces.count - 1)
            }
        }

        // B. The words plus arrow symbols inserted for shape arrows: the arrows go to their stamps.
        let plain = pieces.filter { !arrowSymbols.contains($0) }
        if wordsUsable, plain.count == words.count, plain.count < pieces.count {
            let saved = rowArrows
            var runs: [DigitalTextRun] = []
            var wordIndex = 0
            var complete = true
            for (position, text) in pieces.enumerated() {
                let last = position == pieces.count - 1
                if arrowSymbols.contains(text) {
                    guard let arrow = takeArrow(text) else { complete = false; break }
                    var token = wordToken(text, word: nil)
                    token.drawsVisibly = false
                    token.needsReview = false
                    runs.append(run([token], box(arrow.rect), trailingSpace: !last))
                } else {
                    runs.append(run([wordToken(text, word: wordIndex)], box(words[wordIndex].rect), trailingSpace: !last))
                    wordIndex += 1
                }
            }
            if complete { return runs }
            rowArrows = saved
        }

        // C. The whole line in the line box; words that still match keep their color, weight and review mark.
        let aligned = LineTextAlignment.tokens(of: line.text, words: words)
        let tokens = aligned.map { piece -> DigitalTextRun.Token in
            var token = wordToken(piece.text, word: piece.wordIndex)
            if arrowSymbols.contains(piece.text), takeArrow(piece.text) != nil { token.drawsVisibly = false }
            return token
        }
        return [run(tokens, lineBox, trailingSpace: false, wholeLine: true)]
    }

    // MARK: Drawing

    /// Draws `runs` into `context` (displayed page points, origin bottom-left; any scale may be applied already).
    /// - Parameters:
    ///   - visible: false draws invisible text (text render mode 3) for search, selection and copying, each run
    ///     fitted exactly into its box; true draws the text mode: colored text laid out per line
    ///     (`layoutVisibleLine`), arrows of shape arrows left out, uncertain words underlined.
    ///   - pageWidth: visible text does not reach beyond this x.
    static func draw(_ runs: [DigitalTextRun], in context: CGContext, visible: Bool, pageWidth: Double = .infinity) {
        guard visible else {
            for run in runs { drawInvisible(run, in: context) }
            return
        }
        for (run, layout) in zip(runs, visibleLayouts(runs, pageWidth: pageWidth)) {
            if let layout { drawVisible(run, layout: layout, in: context) }
        }
    }

    /// The text-mode layout of `runs` (nil for runs that are not drawn), line by line with `layoutVisibleLine`.
    static func visibleLayouts(_ runs: [DigitalTextRun], pageWidth: Double = .infinity) -> [VisibleRunLayout?] {
        var result: [VisibleRunLayout?] = []
        // Runs of one line are consecutive (`runs(for:)` emits them line by line).
        var start = 0
        while start < runs.count {
            var end = start + 1
            while end < runs.count, runs[end].lineID == runs[start].lineID { end += 1 }
            let line = runs[start..<end]
            let inputs = line.map { run -> VisibleRunInput in
                let drawn = run.rect.width > 0 && run.rect.height > 0 && run.tokens.contains(where: \.drawsVisibly)
                let unitWidth = drawn ? makeLine(run, size: 100, visible: true).width / 100 : 0
                return VisibleRunInput(rect: run.rect, unitWidth: unitWidth, isWholeLine: run.isWholeLine)
            }
            result += layoutVisibleLine(inputs, lineRect: line[start].lineRect, pageWidth: pageWidth)
            start = end
        }
        return result
    }

    /// Invisible text layer: font size from the line height, then horizontal scaling to the box (the selection then
    /// covers exactly the word's place on the page).
    private static func drawInvisible(_ run: DigitalTextRun, in context: CGContext) {
        guard run.rect.width > 0, run.rect.height > 0, !run.tokens.isEmpty else { return }
        var fontSize = fontSize(forHeight: Double(run.rect.height))
        var line = makeLine(run, size: fontSize, visible: false)
        var natural = line.width
        guard natural > 0 else { return }
        var scale = Double(run.rect.width) / natural
        if scale < minimumScale {
            fontSize *= scale / minimumScale
            line = makeLine(run, size: fontSize, visible: false)
            natural = line.width
            guard natural > 0 else { return }
            scale = min(minimumScale, Double(run.rect.width) / natural)
        }
        scale = min(scale, maximumScale)
        let font = CTFontCreateWithName(regularFont as CFString, fontSize, nil)
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
        let baseline = Double(run.rect.minY) + (Double(run.rect.height) - ascent - descent) / 2 + descent

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: run.rect.minX, y: baseline)
        context.scaleBy(x: scale, y: 1)
        context.textPosition = .zero
        context.setTextDrawingMode(.invisible)
        CTLineDraw(line.line, context)
        context.restoreGState()
    }

    /// Text mode: the run at its laid-out place, uncertain words with a subtle dotted orange line below.
    private static func drawVisible(_ run: DigitalTextRun, layout: VisibleRunLayout, in context: CGContext) {
        let line = makeLine(run, size: layout.fontSize, visible: true)
        let font = CTFontCreateWithName(regularFont as CFString, layout.fontSize, nil)
        let descent = Double(CTFontGetDescent(font))

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: layout.origin.x, y: layout.origin.y)
        context.scaleBy(x: layout.horizontalScale, y: 1)
        context.textPosition = .zero
        context.setTextDrawingMode(.fill)
        CTLineDraw(line.line, context)

        let width = max(0.5, layout.fontSize * 0.06)
        context.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.05, alpha: 0.9))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [0.01, width * 2.5])
        for (token, range) in zip(run.tokens, line.ranges) where token.needsReview && token.drawsVisibly {
            let start = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
            let end = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
            let y = -descent * 0.55
            context.move(to: CGPoint(x: start, y: y))
            context.addLine(to: CGPoint(x: end, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Visible layout

    /// One run of a line for `layoutVisibleLine`.
    struct VisibleRunInput {
        /// The run's box (word box or line box), displayed page points.
        var rect: CGRect
        /// Natural width of the run's text at font size 1; 0 for a run that is not drawn (it still ends the word
        /// before it, e.g. an arrow that the page shows as a shape).
        var unitWidth: Double
        var isWholeLine: Bool
    }

    /// Lays out the visible runs of one line (text mode) so that the text looks typed, not fitted:
    /// - one font size (from the line height) and one baseline for the whole line;
    /// - each run starts at its box's minX, horizontally scaled only within `visibleMinimumScale…visibleMaximumScale`
    ///   towards its box width (coarse word boxes neither stretch nor squash the words);
    /// - a run that would reach the next run of the line (minus `visibleGap` spaces) is squeezed to the minimum scale
    ///   and, if still too long, set in a smaller font on the same baseline. If a quarter or more of the runs would
    ///   need that, the whole line gets the smaller size instead (down to `minimumLineFactor`), so that the line
    ///   stays uniform;
    /// - a whole-line run may be `wholeLineOverflow` times as wide as the line box; the last word may reach
    ///   `lastWordOverflow` line heights beyond its box.
    /// - Returns: a layout per input, nil for runs that are not drawn.
    static func layoutVisibleLine(
        _ runs: [VisibleRunInput], lineRect: CGRect, pageWidth: Double = .infinity
    ) -> [VisibleRunLayout?] {
        let lineHeight = Double(lineRect.height)
        guard lineHeight > 0 else { return runs.map { _ in nil } }
        let reference = CTFontCreateWithName(regularFont as CFString, 100, nil)
        let ascentUnit = Double(CTFontGetAscent(reference)) / 100, descentUnit = Double(CTFontGetDescent(reference)) / 100
        let spaceUnit = spaceWidth(of: reference) / 100
        let lineSize = fontSize(forHeight: lineHeight)
        let gap = visibleGap * spaceUnit * lineSize

        // Room of each drawn run: from its minX to the next run's minX (minus the gap) or its overflow limit.
        let rooms: [Double?] = runs.indices.map { index in
            let run = runs[index]
            guard run.unitWidth > 0, run.rect.width > 0 else { return nil }
            let minX = Double(run.rect.minX)
            let next = runs.indices
                .filter { $0 != index && Double(runs[$0].rect.minX) > minX + 0.01 * lineHeight }
                .map { Double(runs[$0].rect.minX) }.min()
            var limit: Double
            if let next {
                limit = next - gap
            } else if run.isWholeLine {
                limit = Double(lineRect.minX) + wholeLineOverflow * Double(lineRect.width)
            } else {
                limit = max(Double(run.rect.maxX), Double(lineRect.maxX)) + lastWordOverflow * lineHeight
            }
            limit = min(limit, pageWidth)
            // Overlapping or unordered boxes: keep a little room instead of a vanishing word.
            return max(limit - minX, 0.25 * lineHeight)
        }

        // Shrink factor each run would need at the minimum scale. The lower quartile decides the size of the whole
        // line (handwriting of one writer is narrower or wider than the font throughout), but never below
        // `minimumLineFactor` for the sake of a single odd box; runs that still do not fit are forced individually.
        let needed = runs.indices.compactMap { index -> Double? in
            guard let room = rooms[index] else { return nil }
            return min(1, room / (runs[index].unitWidth * lineSize * visibleMinimumScale))
        }.sorted()
        let lineFactor = needed.isEmpty ? 1 : max(minimumLineFactor, needed[(needed.count - 1) / 4])
        let size = max(0.5, lineSize * lineFactor)
        let baseline = Double(lineRect.minY) + (lineHeight - (ascentUnit + descentUnit) * size) / 2 + descentUnit * size

        return runs.indices.map { index in
            guard let room = rooms[index] else { return nil }
            let run = runs[index]
            var wordSize = size
            let natural = run.unitWidth * size
            var scale = min(visibleMaximumScale, max(visibleMinimumScale, Double(run.rect.width) / natural))
            if natural * scale > room {
                scale = max(visibleMinimumScale, room / natural)
                if natural * scale > room {
                    // Forced: a smaller font on the line's baseline.
                    wordSize = max(0.5, size * room / (natural * scale))
                }
            }
            return VisibleRunLayout(
                origin: CGPoint(x: run.rect.minX, y: baseline), fontSize: wordSize, horizontalScale: scale,
                width: run.unitWidth * wordSize * scale)
        }
    }

    private static func spaceWidth(of font: CTFont) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: " ", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// Font size whose ascent + descent fill `heightFill` of the line height.
    static func fontSize(forHeight height: Double) -> Double {
        let reference = CTFontCreateWithName(regularFont as CFString, 100, nil)
        let unit = (Double(CTFontGetAscent(reference)) + Double(CTFontGetDescent(reference))) / 100
        return max(0.5, height * heightFill / max(unit, 0.1))
    }

    /// The run as a CoreText line (tokens joined by spaces, the trailing space not included in `ranges`).
    private static func makeLine(
        _ run: DigitalTextRun, size: Double, visible: Bool
    ) -> (line: CTLine, ranges: [NSRange], width: Double) {
        let regular = CTFontCreateWithName(regularFont as CFString, size, nil)
        let bold = CTFontCreateWithName(boldFont as CFString, size, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let text = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (index, token) in run.tokens.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: " ", attributes: [fontKey: regular, colorKey: clear]))
            }
            let color = visible && !token.drawsVisibly
                ? clear
                : CGColor(srgbRed: token.color.red, green: token.color.green, blue: token.color.blue, alpha: 1)
            let start = text.length
            text.append(NSAttributedString(string: token.text, attributes: [fontKey: token.bold ? bold : regular, colorKey: color]))
            ranges.append(NSRange(location: start, length: text.length - start))
        }
        let measured = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(measured, nil, nil, nil)
        guard run.trailingSpace else { return (measured, ranges, width) }
        // The trailing space is drawn but not measured: the visible text fills exactly the box.
        text.append(NSAttributedString(string: " ", attributes: [fontKey: regular, colorKey: clear]))
        return (CTLineCreateWithAttributedString(text), ranges, width)
    }
}
