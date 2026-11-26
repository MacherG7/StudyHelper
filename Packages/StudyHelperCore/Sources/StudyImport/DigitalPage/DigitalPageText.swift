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
    /// The paragraph of the line (lines of one paragraph share one font size in text mode).
    var paragraphID: UUID? = nil
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
    /// Visible text: ascent + descent of a line fill at most this share of the row pitch (distance between the
    /// centers of neighboring rows) or of the free band between fixed obstacles, so that dense handwriting with
    /// overlapping line boxes does not overlap as text.
    static let pitchFill = 0.9
    /// Visible text: lines on the same row (centers closer than this many of the smaller line height) share size and
    /// baseline, as long as they are at most `sameRowGap` line heights apart horizontally.
    static let sameRowTolerance = 0.35
    static let sameRowGap = 3.0
    /// Visible text: neighbors must overlap horizontally by this share of the narrower line.
    static let neighborOverlap = 0.1
    /// Visible text: neither the row pitch nor the paragraph uniformity shrink a line below this share of the size
    /// from its height.
    static let minimumPitchFactor = 0.45
    static let minimumParagraphFactor = 0.7
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
                isWholeLine: wholeLine, paragraphID: line.paragraphID)
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
    ///   - obstacles: boxes of lines that stay on the page as they are (printed text, text in pictures, writing that
    ///     is not replaced): visible text keeps clear of them (`linePlacements`).
    static func draw(
        _ runs: [DigitalTextRun], in context: CGContext, visible: Bool, pageWidth: Double = .infinity,
        obstacles: [CGRect] = []
    ) {
        guard visible else {
            for run in runs { drawInvisible(run, in: context) }
            return
        }
        for (run, layout) in zip(runs, visibleLayouts(runs, pageWidth: pageWidth, obstacles: obstacles)) {
            if let layout { drawVisible(run, layout: layout, in: context) }
        }
    }

    /// Boxes (displayed page points, origin bottom-left) of the lines in `lines` that are not among `shown`: they
    /// stay visible on the page, so the drawn text must not run over them.
    static func obstacleRects(of lines: [RecognizedLine], excluding shown: [RecognizedLine], size: PageSize) -> [CGRect] {
        let drawn = Set(shown.map(\.id))
        return lines.filter { line in
            !drawn.contains(line.id) && !line.rect.isEmpty
                && (!line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.status == .illegible)
        }.map { line in
            let l = line.rect.toBottomLeft(spaceWidth: size.width, spaceHeight: size.height)
            return CGRect(x: l.x, y: l.y, width: l.width, height: l.height)
        }
    }

    /// The text-mode layout of `runs` (nil for runs that are not drawn), line by line with `layoutVisibleLine`.
    /// Font size and vertical place of each line come from `linePlacements` (neighboring rows never overlap).
    static func visibleLayouts(
        _ runs: [DigitalTextRun], pageWidth: Double = .infinity, obstacles: [CGRect] = []
    ) -> [VisibleRunLayout?] {
        // Runs of one line are consecutive (`runs(for:)` emits them line by line).
        var ranges: [Range<Int>] = []
        var start = 0
        while start < runs.count {
            var end = start + 1
            while end < runs.count, runs[end].lineID == runs[start].lineID { end += 1 }
            ranges.append(start..<end)
            start = end
        }
        let placements = linePlacements(
            rects: ranges.map { runs[$0.lowerBound].lineRect }, paragraphs: ranges.map { runs[$0.lowerBound].paragraphID },
            obstacles: obstacles)
        var result: [VisibleRunLayout?] = []
        for (range, placement) in zip(ranges, placements) {
            let line = runs[range]
            let inputs = line.map { run -> VisibleRunInput in
                let drawn = run.rect.width > 0 && run.rect.height > 0 && run.tokens.contains(where: \.drawsVisibly)
                let unitWidth = drawn ? makeLine(run, size: 100, visible: true).width / 100 : 0
                return VisibleRunInput(rect: run.rect, unitWidth: unitWidth, isWholeLine: run.isWholeLine)
            }
            result += layoutVisibleLine(
                inputs, lineRect: runs[range.lowerBound].lineRect, pageWidth: pageWidth,
                maximumSize: placement.maximumSize, centerY: placement.centerY)
        }
        return result
    }

    /// Size limit and vertical center of one line in text mode.
    struct LinePlacement: Equatable {
        /// The line's font size is at most this (points).
        var maximumSize: Double
        /// The ascent + descent of the line are centered on this y (displayed page points, origin bottom-left).
        var centerY: Double
    }

    /// Where the lines of a page may put their text so that rows never overlap, although the recognized line boxes
    /// of dense handwriting do (ascenders and descenders make a box about twice as high as the row pitch):
    /// - Lines on the same row (centers within `sameRowTolerance` × the smaller height, close horizontally) form a
    ///   group with one size and one center (their mean).
    /// - A group's size is at most `pitchFill` of the pitch (distance between the centers) to the nearest group above
    ///   and below that overlaps it horizontally, and at most the size from its line heights.
    /// - Obstacles (lines that are not drawn but stay on the page, e.g. a printed question above a handwritten
    ///   answer) are walls: if one reaches into the line's box from above (below), the text goes into the free band
    ///   between the wall and the box's bottom (top) edge, because the part of the box next to the wall is only the
    ///   reach of ascenders (descenders); size and center follow that band.
    /// - A size is never below `minimumPitchFactor` of the one from its height, so that duplicate boxes do not make
    ///   the text vanish.
    /// - Lines of one paragraph share the smallest size of the paragraph, but no line is set below
    ///   `minimumParagraphFactor` of its own size; same-row groups are then made uniform again.
    /// - Parameters: `rects` the line boxes (displayed page points, origin bottom-left), `paragraphs` their
    ///   paragraphs, `obstacles` boxes of fixed lines.
    static func linePlacements(rects: [CGRect], paragraphs: [UUID?], obstacles: [CGRect] = []) -> [LinePlacement] {
        let count = rects.count
        guard count > 0 else { return [] }
        let reference = CTFontCreateWithName(regularFont as CFString, 100, nil)
        let unit = (Double(CTFontGetAscent(reference)) + Double(CTFontGetDescent(reference))) / 100
        let heightSizes = rects.map { fontSize(forHeight: Double($0.height)) }

        // Same-row groups (union-find).
        var parent = Array(0..<count)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root { (node, parent[node]) = (parent[node], root) }
            return root
        }
        for a in 0..<count where rects[a].height > 0 {
            guard a + 1 < count else { break }
            for b in (a + 1)..<count where rects[b].height > 0 {
                let smaller = Double(min(rects[a].height, rects[b].height))
                let larger = Double(max(rects[a].height, rects[b].height))
                let gap = max(Double(rects[a].minX), Double(rects[b].minX)) - min(Double(rects[a].maxX), Double(rects[b].maxX))
                if abs(Double(rects[a].midY - rects[b].midY)) <= sameRowTolerance * smaller, gap <= sameRowGap * larger {
                    parent[find(a)] = find(b)
                }
            }
        }
        var members: [Int: [Int]] = [:]
        for index in 0..<count where rects[index].height > 0 { members[find(index), default: []].append(index) }
        let roots = members.keys.sorted()
        let center = Dictionary(uniqueKeysWithValues: roots.map { root in
            (root, members[root]!.map { Double(rects[$0].midY) }.reduce(0, +) / Double(members[root]!.count))
        })

        func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
            let shared = Double(min(a.maxX, b.maxX) - max(a.minX, b.minX))
            return shared > 0 && shared >= neighborOverlap * Double(min(a.width, b.width))
        }
        func overlaps(_ a: [Int], _ b: [Int]) -> Bool {
            a.contains { i in b.contains { j in overlap(rects[i], rects[j]) } }
        }

        var placement: [Int: (size: Double, center: Double)] = [:]
        for root in roots {
            let group = members[root]!
            let c = center[root]!
            let fromHeight = group.map { heightSizes[$0] }.min()!
            let smallestHeight = Double(group.map { rects[$0].height }.min()!)
            let boxBottom = Double(group.map { rects[$0].minY }.min()!)
            let boxTop = Double(group.map { rects[$0].maxY }.max()!)

            // Pitch to the nearest drawn rows above and below.
            var above = Double.infinity, below = Double.infinity
            for other in roots where other != root && overlaps(group, members[other]!) {
                let distance = center[other]! - c
                if distance > 1e-9 { above = min(above, distance) } else if distance < -1e-9 { below = min(below, -distance) }
            }
            // Walls: obstacles that reach into the box from above or below (not on the same row).
            var wallAbove = Double.infinity, wallBelow = -Double.infinity
            for obstacle in obstacles where obstacle.height > 0 && group.contains(where: { overlap(rects[$0], obstacle) }) {
                let sameRow = abs(Double(obstacle.midY) - c) <= sameRowTolerance * min(Double(obstacle.height), smallestHeight)
                guard !sameRow else { continue }
                if Double(obstacle.midY) > c, Double(obstacle.minY) < boxTop { wallAbove = min(wallAbove, Double(obstacle.minY)) }
                if Double(obstacle.midY) < c, Double(obstacle.maxY) > boxBottom { wallBelow = max(wallBelow, Double(obstacle.maxY)) }
            }
            var size: Double, middle = c
            if wallAbove.isFinite || wallBelow.isFinite {
                // Free band: from the wall to the box edge on the other side, within the half pitch to the neighbors.
                var top = min(boxTop, wallAbove), bottom = max(boxBottom, wallBelow)
                if above.isFinite { top = min(top, c + pitchFill / 2 * above) }
                if below.isFinite { bottom = max(bottom, c - pitchFill / 2 * below) }
                let band = top - bottom
                if band > 0 {
                    size = min(fromHeight, pitchFill * band / unit)
                    middle = (top + bottom) / 2
                } else {
                    size = minimumPitchFactor * fromHeight
                }
            } else {
                let pitch = min(above, below)
                size = pitch.isFinite ? min(fromHeight, pitchFill * pitch / unit) : fromHeight
            }
            placement[root] = (max(size, minimumPitchFactor * fromHeight), middle)
        }
        var size = (0..<count).map { rects[$0].height > 0 ? placement[find($0)]!.size : heightSizes[$0] }

        // Paragraph uniformity.
        var smallest: [UUID: Double] = [:]
        for index in 0..<count {
            if let id = paragraphs[index], rects[index].height > 0 { smallest[id] = min(smallest[id] ?? .infinity, size[index]) }
        }
        let own = size
        for index in 0..<count {
            if let id = paragraphs[index], let shared = smallest[id], rects[index].height > 0 {
                size[index] = max(shared, minimumParagraphFactor * own[index])
            }
        }
        // Same-row groups stay uniform.
        for root in roots {
            let shared = members[root]!.map { size[$0] }.min()!
            for index in members[root]! { size[index] = shared }
        }
        return (0..<count).map { index in
            LinePlacement(
                maximumSize: size[index],
                centerY: rects[index].height > 0 ? placement[find(index)]!.center : Double(rects[index].midY))
        }
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
    /// - `maximumSize` caps the font size (row pitch, free band; see `linePlacements`); `centerY` centers the text's
    ///   ascent + descent on this y instead of the line box's center.
    static func layoutVisibleLine(
        _ runs: [VisibleRunInput], lineRect: CGRect, pageWidth: Double = .infinity,
        maximumSize: Double = .infinity, centerY: Double? = nil
    ) -> [VisibleRunLayout?] {
        let lineHeight = Double(lineRect.height)
        guard lineHeight > 0 else { return runs.map { _ in nil } }
        let reference = CTFontCreateWithName(regularFont as CFString, 100, nil)
        let ascentUnit = Double(CTFontGetAscent(reference)) / 100, descentUnit = Double(CTFontGetDescent(reference)) / 100
        let spaceUnit = spaceWidth(of: reference) / 100
        let lineSize = min(fontSize(forHeight: lineHeight), max(0.5, maximumSize))
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
        let center = centerY ?? Double(lineRect.midY)
        let baseline = center - (ascentUnit + descentUnit) * size / 2 + descentUnit * size

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
