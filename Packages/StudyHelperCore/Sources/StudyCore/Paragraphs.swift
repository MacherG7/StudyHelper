import Foundation

/// A paragraph of a digitized page: consecutive lines of one text joined, with its position on the page.
/// Lines stay the unit of review and correction; a paragraph is built from its lines (`ParagraphGrouping`), so
/// corrections of a line show up in the paragraph text.
public struct TextParagraph: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The lines' texts joined; words split by a line-end hyphen are rejoined ("Glo-" + "balen" → "Globalen").
    public var text: String
    /// Union of the line rects (page fractions, origin top-left).
    public var rect: NormalizedRect
    /// The lines in reading order.
    public var lineIDs: [UUID]
    /// Starts with a list marker ("-", "•", "1.", "→" …).
    public var isListItem: Bool

    public init(id: UUID, text: String, rect: NormalizedRect, lineIDs: [UUID], isListItem: Bool) {
        self.id = id
        self.text = text
        self.rect = rect
        self.lineIDs = lineIDs
        self.isListItem = isListItem
    }
}

/// Groups the recognized lines of a page into paragraphs: a line continues a paragraph if it sits directly
/// below the paragraph's last row (or right next to it on the same row), overlaps it horizontally, has the same
/// color and does not start a new list item. Works on any page layout (columns, mind maps), because a line is
/// attached to whichever open paragraph it continues, not just to the line before it in reading order.
public enum ParagraphGrouping {
    /// Largest gap between a paragraph's last row and the next row, in median line heights (an empty row on lined
    /// or squared paper is about one line height and separates paragraphs).
    public static let maximumRowGap = 0.5
    /// Printed text (no pen color: text layer or text in images) has regular, wider line spacing; paragraphs there
    /// are marked by list markers and indentation instead. Largest gap, in the lines' own heights.
    public static let maximumPrintedRowGap = 1.2
    /// Rows may overlap (descenders, imprecise boxes of dense handwriting), in median line heights.
    public static let maximumRowOverlap = 0.8
    /// A row narrower than this share of the page's full line width is short (heading, list entry, label): the
    /// next row continues it only after a line-end hyphen or when it starts in lower case.
    public static let shortRow = 0.6
    /// The next row must share at least this share of the narrower row's width.
    public static let minimumHorizontalOverlap = 0.25
    /// Lines on the same row (centers within half a line height) closer than this are one row of the paragraph.
    public static let maximumSameRowGap = 2.0
    /// Printed paragraphs in block justification: pieces of one row may be this far apart (in line heights) as long
    /// as they stay within the paragraph's width.
    public static let maximumJustifiedGap = 5.0
    /// Placeholder for an illegible line inside a paragraph (as in `OriginalTextMarkdown`).
    public static let illegiblePlaceholder = "[unleserlich]"

    /// Words after a hyphenated line end that mean the hyphen is a suspended compound ("Schnee- und Eisflächen").
    private static let conjunctions: Set<String> = ["und", "oder", "bzw", "bzw.", "sowie", "bis", "als", "wie"]
    private static let listMarker = try! NSRegularExpression(
        pattern: "^\\s*(?:[-–—•·▪◦*→>]|\\d{1,3}[.)]?(?=\\s|$)|[a-z][)])")

    /// True if the text starts like a list item.
    public static func startsListItem(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Sets `paragraphID` on every line. Lines keep their order; ids are fresh for every call.
    public static func assign(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let text = lines.filter { !$0.rect.isEmpty && $0.status != .illegible }
        let heights = text.map(\.rect.height).sorted()
        let h = heights.isEmpty ? 0.02 : heights[heights.count / 2]
        let widths = text.map(\.rect.width).sorted()
        let fullWidth = widths.isEmpty ? 1 : widths[min(widths.count - 1, Int(Double(widths.count) * 0.9))]

        struct Open {
            var id: UUID
            var color: String?
            var firstMinX: Double
            /// Union of the members on the last row.
            var lastRow: NormalizedRect
            /// Text of the last line (for the short-row rule).
            var lastText: String
            var rowCount = 1
            /// Union of all rows (justified printed text is split into pieces with wide gaps inside this extent).
            var extent: NormalizedRect
            /// Left edge of the second row: with a hanging indent, a row starting further left is a new entry.
            var secondRowMinX: Double?
        }
        var open: [Open] = []
        var result = lines
        for index in result.indices.sorted(by: { result[$0].order < result[$1].order }) {
            let line = result[index]
            // Illegible ink and empty boxes are paragraphs of their own: nothing to join, and they must not chain
            // separate entries (a column of unreadable list numbers).
            guard !line.rect.isEmpty, line.status != .illegible, !line.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                result[index].paragraphID = UUID()
                continue
            }
            let color = line.color?.hex
            let isList = startsListItem(line.text)
            var best: (position: Int, score: Double)?
            for (position, paragraph) in open.enumerated() where paragraph.color == color {
                let row = paragraph.lastRow
                let sameRow = abs(line.rect.midY - row.midY) < 0.5 * h
                if sameRow {
                    // Right next to the row (e.g. after an arrow): same row of the paragraph.
                    let gap = line.rect.minX - row.maxX
                    let insideJustified = color == nil && paragraph.rowCount > 1
                        && line.rect.maxX <= paragraph.extent.maxX + h
                    let limit = insideJustified ? maximumJustifiedGap : maximumSameRowGap
                    guard !isList, gap >= -0.5 * h, gap <= limit * h else { continue }
                    let score = gap / h
                    if score < (best?.score ?? .infinity) { best = (position, score) }
                    continue
                }
                guard !isList, line.rect.midY > row.midY + 0.5 * h else { continue }
                let gap = line.rect.minY - row.maxY
                let gapLimit = color == nil
                    ? maximumPrintedRowGap * (line.rect.height + row.height) / 2 : maximumRowGap * h
                guard gap >= -maximumRowOverlap * h, gap <= gapLimit else { continue }
                if let indent = paragraph.secondRowMinX, indent > paragraph.firstMinX + 0.5 * h,
                   line.rect.minX < indent - h { continue }
                let overlap = min(line.rect.maxX, row.maxX) - max(line.rect.minX, row.minX)
                guard overlap >= minimumHorizontalOverlap * min(line.rect.width, row.width),
                      line.rect.minX >= paragraph.firstMinX - h else { continue }
                if row.width < shortRow * fullWidth, !endsWithWordHyphen(paragraph.lastText),
                   !(line.text.first?.isLowercase ?? false) { continue }
                let score = 10 + gap / h
                if score < (best?.score ?? .infinity) { best = (position, score) }
            }
            if let best {
                var paragraph = open[best.position]
                let row = paragraph.lastRow
                paragraph.extent = paragraph.extent.union(line.rect)
                if abs(line.rect.midY - row.midY) < 0.5 * h {
                    paragraph.lastRow = row.union(line.rect)
                } else {
                    paragraph.lastRow = line.rect
                    paragraph.rowCount += 1
                    if paragraph.rowCount == 2 { paragraph.secondRowMinX = line.rect.minX }
                }
                paragraph.lastText = line.text.trimmingCharacters(in: .whitespaces)
                open[best.position] = paragraph
                result[index].paragraphID = paragraph.id
            } else {
                let id = UUID()
                open.append(Open(
                    id: id, color: color, firstMinX: line.rect.minX, lastRow: line.rect,
                    lastText: line.text.trimmingCharacters(in: .whitespaces), extent: line.rect))
                result[index].paragraphID = id
            }
        }
        return result
    }

    /// The paragraphs of `lines` in reading order (order of their first line). Lines without `paragraphID` are
    /// paragraphs of their own.
    public static func paragraphs(of lines: [RecognizedLine]) -> [TextParagraph] {
        var groups: [UUID: [RecognizedLine]] = [:]
        var keys: [UUID] = []
        for line in lines.sorted(by: { $0.order < $1.order }) {
            let key = line.paragraphID ?? line.id
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(line)
        }
        return keys.map { key in
            let members = groups[key] ?? []
            return TextParagraph(
                id: key, text: join(members), rect: members.dropFirst().reduce(members.first?.rect ?? .zero) { $0.union($1.rect) },
                lineIDs: members.map(\.id), isListItem: members.first.map { startsListItem($0.text) } ?? false)
        }
    }

    /// Joins the texts of a paragraph's lines (reading order) into running text.
    public static func join(_ lines: [RecognizedLine]) -> String {
        var text = ""
        for line in lines {
            let part = line.status == .illegible && line.text.trimmingCharacters(in: .whitespaces).isEmpty
                ? illegiblePlaceholder : line.text.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if text.isEmpty {
                text = part
            } else if endsWithWordHyphen(text), let first = part.first, first.isLowercase,
                      !conjunctions.contains(firstWord(of: part).lowercased()) {
                text.removeLast()
                text += part
            } else {
                text += " " + part
            }
        }
        return text
    }

    private static func endsWithWordHyphen(_ text: String) -> Bool {
        guard text.hasSuffix("-"), text.count >= 2 else { return false }
        return text[text.index(text.endIndex, offsetBy: -2)].isLetter
    }

    private static func firstWord(of text: String) -> String {
        String(text.prefix { !$0.isWhitespace && $0 != "," && $0 != ")" })
    }
}
