import Foundation

/// German spell checking for the word review. The app implements it with `UITextChecker` (language "de"); tests use
/// a fixed word list.
public protocol SpellChecking: Sendable {
    /// Whether the word (without surrounding punctuation) is spelled correctly.
    func isKnown(_ word: String) -> Bool
    /// Corrections for a misspelled word, best first.
    func guesses(for word: String) -> [String]
}

/// Remembers a spell checker's answers per word (thread-safe), so that reviewing a page again does not ask the
/// checker again. Create one per checker and keep it while the checker's dictionary stays the same.
public final class CachingSpellChecker: SpellChecking, @unchecked Sendable {
    public let base: any SpellChecking
    private let lock = NSLock()
    private var known: [String: Bool] = [:]
    private var guessed: [String: [String]] = [:]
    /// Above this many cached words the cache starts over (bounds memory on long sessions).
    private let limit: Int

    public init(_ base: any SpellChecking, limit: Int = 20_000) {
        self.base = base
        self.limit = max(1, limit)
    }

    public func isKnown(_ word: String) -> Bool {
        if let cached = lock.withLock({ known[word] }) { return cached }
        let answer = base.isKnown(word)
        lock.withLock {
            if known.count >= limit { known.removeAll(keepingCapacity: true) }
            known[word] = answer
        }
        return answer
    }

    public func guesses(for word: String) -> [String] {
        if let cached = lock.withLock({ guessed[word] }) { return cached }
        let answer = base.guesses(for: word)
        lock.withLock {
            if guessed.count >= limit { guessed.removeAll(keepingCapacity: true) }
            guessed[word] = answer
        }
        return answer
    }

    /// Forgets every answer (e.g. after the user learned a word in the system dictionary).
    public func removeAll() {
        lock.withLock {
            known.removeAll()
            guessed.removeAll()
        }
    }
}

/// One reviewable word of a line.
public struct ReviewToken: Hashable, Sendable {
    /// Position in the line (0-based). Equals the index into `RecognizedLine.words` when the words match the text.
    public var index: Int
    /// The word as written, including attached punctuation ("„System", "Erde)").
    public var text: String
    /// Range of `text` in `RecognizedLine.text`.
    public var range: Range<String.Index>
    /// Word rect, or a proportional slice of the line rect when the recognizer gave none.
    public var rect: NormalizedRect
    public var status: ConfidenceStatus
    /// Corrected or confirmed by the user in the word review.
    public var isUserConfirmed: Bool
    /// Index into `RecognizedLine.words`, if this token has a recognized word.
    public var wordIndex: Int?

    /// The word without surrounding punctuation and quotes ("„System" → "System").
    public var core: String { WordReview.splitPunctuation(text).core }
}

/// Word-level review: which single words of a page the user should look at, and local suggestions for them.
///
/// A word is marked when the recognizer is unsure about it (status not confident) or, for confident words, when the
/// spell checker does not know it and it is no subject term. Lines the user corrected as a whole are never marked;
/// after word-level corrections only the words the user has not touched yet can be marked.
public enum WordReview {
    /// Why a word is marked.
    public enum MarkReason: String, Hashable, Sendable {
        /// The recognizer flagged the word (uncertain or illegible).
        case recognizer
        /// Confident reading, but not in the dictionary nor a subject term.
        case spelling
    }

    public struct Result: Hashable, Sendable {
        /// Line id → indexes (`ReviewToken.index`) of the words to review, ascending.
        public var marks: [UUID: [Int]]
        /// Why each marked word is marked.
        public var reasons: [WordReference: MarkReason]
        /// Empty lines the recognizer could not read at all ("unleserlich"); each is one open place.
        public var illegibleLines: [UUID]

        /// Open places: marked words plus illegible lines.
        public var openCount: Int { marks.values.reduce(0) { $0 + $1.count } + illegibleLines.count }

        public init(marks: [UUID: [Int]] = [:], reasons: [WordReference: MarkReason] = [:], illegibleLines: [UUID] = []) {
            self.marks = marks
            self.reasons = reasons
            self.illegibleLines = illegibleLines
        }
    }

    // MARK: Tokens

    /// The reviewable words of a line: `WordTokenizer` tokens of `line.text` (pure punctuation such as "•" or "-"
    /// is no word), aligned with `line.words`.
    public static func tokens(of line: RecognizedLine) -> [ReviewToken] {
        let tokens = WordTokenizer.tokens(in: line.text)
        let words = line.words
        let aligned = tokens.count == words.count
            && zip(tokens, words).allSatisfy { same($0.original, $1.text) }
        let total = max(1, line.text.count)
        var cursor = 0
        var result: [ReviewToken] = []
        for (index, token) in tokens.enumerated() {
            var wordIndex: Int?
            if aligned {
                wordIndex = index
            } else if cursor < words.count {
                // Greedy match within a small window: tokens and words mostly agree, some words may be missing.
                let window = cursor..<min(words.count, cursor + 3)
                if let found = window.first(where: { same(token.original, words[$0].text) }) {
                    wordIndex = found
                    cursor = found + 1
                }
            }
            let rect: NormalizedRect
            let status: ConfidenceStatus
            let confirmed: Bool
            if let wordIndex {
                let word = words[wordIndex]
                rect = word.rect.isEmpty ? slice(of: line, range: token.range, total: total) : word.rect
                status = word.status
                confirmed = word.isUserConfirmed
            } else {
                rect = slice(of: line, range: token.range, total: total)
                status = inheritedStatus(of: line)
                confirmed = false
            }
            result.append(ReviewToken(
                index: index, text: token.original, range: token.range, rect: rect, status: status,
                isUserConfirmed: confirmed, wordIndex: wordIndex))
        }
        return result
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }

    /// Status of a token without recognized word: the line's status, except for lines that are only flagged as a
    /// whole because they were re-read (D-020: there the words keep their own status, i.e. confident).
    static func inheritedStatus(of line: RecognizedLine) -> ConfidenceStatus {
        switch line.status {
        case .confident: return .confident
        case .illegible: return .illegible
        case .uncertain:
            let lineOnly: Set<ReviewReason> = [.reReadSeparately, .confirmedByReducedPDF]
            return line.reviewReasons.allSatisfy(lineOnly.contains) ? .confident : .uncertain
        }
    }

    static func slice(of line: RecognizedLine, range: Range<String.Index>, total: Int) -> NormalizedRect {
        let start = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
        let length = line.text.distance(from: range.lowerBound, to: range.upperBound)
        let r = line.rect
        return NormalizedRect(
            x: r.minX + r.width * Double(start) / Double(total), y: r.minY,
            width: r.width * Double(length) / Double(total), height: r.height)
    }

    // MARK: Marks

    /// Whether a line's text is exact and never marked: embedded PDF text or a Goodnotes text box. Decided only by
    /// `RecognizedLine.origin`; lines without origin (digitized before it was stored) are checked like recognized text
    /// (typed text passes the spell check anyway). A recognizer may report confidence 1 for handwriting, so the
    /// confidence says nothing about the origin.
    public static func isEmbedded(_ line: RecognizedLine) -> Bool {
        line.origin == .pdfText || line.origin == .freeText
    }

    /// Line id → word indexes to review (see `review`).
    public static func marks(
        for lines: [RecognizedLine], checker: any SpellChecking, terms: Set<String> = [],
        isEmbedded: (RecognizedLine) -> Bool = WordReview.isEmbedded
    ) -> [UUID: [Int]] {
        review(lines, checker: checker, terms: terms, isEmbedded: isEmbedded).marks
    }

    /// Marks the words of one page.
    /// - Parameters:
    ///   - lines: the lines of the page (any order; `order` is used for line-break hyphenation).
    ///   - checker: the spell checker. Wrap it once in a `CachingSpellChecker` and reuse that to avoid asking the
    ///     checker again for the same words on every review; otherwise answers are cached for this call only.
    ///   - terms: subject terms ("Fachbegriffe"), compared case-insensitively; they count as spelled correctly.
    ///   - isEmbedded: exact lines (embedded PDF text, text boxes) that are never marked; default `isEmbedded(_:)`.
    public static func review(
        _ lines: [RecognizedLine], checker: any SpellChecking, terms: Set<String> = [],
        isEmbedded: (RecognizedLine) -> Bool = WordReview.isEmbedded
    ) -> Result {
        let cached = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let dictionary = Lexicon(checker: cached, terms: terms)
        let ordered = lines.sorted { $0.order < $1.order }
        let tokensByLine = ordered.map { tokens(of: $0) }
        var result = Result()

        for (position, line) in ordered.enumerated() {
            if isEmbedded(line) { continue }
            if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if line.status == .illegible, !line.isUserCorrected { result.illegibleLines.append(line.id) }
                continue
            }
            let tokens = tokensByLine[position]
            // A line corrected or confirmed as a whole has been checked completely.
            if line.isUserCorrected, !tokens.contains(where: \.isUserConfirmed) { continue }
            let next = position + 1 < ordered.count ? tokensByLine[position + 1].first : nil
            let previous = position > 0 ? tokensByLine[position - 1].last : nil
            var marked: [Int] = []
            for token in tokens where !token.isUserConfirmed && !isStructural(token.text) {
                let reason: MarkReason?
                if token.status != .confident {
                    reason = .recognizer
                } else {
                    let isLast = token.index == tokens.count - 1
                    let isFirst = token.index == 0
                    // Words that may complete a hyphen fragment: the rest of the line, then the first words of the
                    // next lines (the reading order may put the continuation a line further down).
                    var following: [String] = []
                    if splitPunctuation(token.text).trailing.hasPrefix("-") {
                        following = tokens.dropFirst(token.index + 1).prefix(fragmentLookahead).map(\.text)
                        for later in tokensByLine.dropFirst(position + 1).prefix(fragmentLineLookahead) {
                            if let first = later.first { following.append(first.text) }
                        }
                    }
                    reason = isSpelledCorrectly(
                        token.text, dictionary: dictionary, nextLineStart: isLast ? next?.text : nil,
                        previousLineEnd: isFirst ? previous?.text : nil, following: following) ? nil : .spelling
                }
                if let reason {
                    marked.append(token.index)
                    result.reasons[WordReference(lineID: line.id, wordIndex: token.index)] = reason
                }
            }
            if !marked.isEmpty { result.marks[line.id] = marked }
        }
        return result
    }

    /// Tokens that are never marked: punctuation, arrows ("→", "->", "=>"), bullets, single letters and numbers or
    /// ordinals ("1.", "2)", "3,5").
    static func isStructural(_ token: String) -> Bool {
        let core = splitPunctuation(token).core
        if core.isEmpty { return true }
        if core.count == 1 { return true }
        let numberCharacters = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".,:/-–"))
        if core.unicodeScalars.allSatisfy(numberCharacters.contains) { return true }
        return false
    }

    /// Words after a hyphen fragment on the same line that may complete it ("Atmo-, Hydro- und Biosphäre").
    static let fragmentLookahead = 6
    /// Following lines whose first word may continue a line-final hyphen fragment.
    static let fragmentLineLookahead = 3
    /// Longest abbreviation with a final period that is not spell-checked ("medz.", "etz.", "bzw.").
    static let maximumAbbreviationLetters = 5

    /// The spell-check rule for a confident word (the token as written, with punctuation).
    /// - Parameter following: words after the token (rest of the line, then the next lines' first words); used only
    ///   for hyphen fragments.
    static func isSpelledCorrectly(
        _ token: String, dictionary: Lexicon, nextLineStart: String?, previousLineEnd: String?,
        following: [String] = []
    ) -> Bool {
        let parts = splitPunctuation(token)
        let core = parts.core
        guard !core.isEmpty else { return true }
        // Not judged by the spell checker: words with digits ("CO2"), short all-caps words ("DNA", "USA") and
        // abbreviations ("z.B.", "sog.", "medz.").
        if core.contains(where: \.isNumber) { return true }
        let letters = core.filter(\.isLetter)
        if letters.count <= 6, !letters.isEmpty, letters.allSatisfy(\.isUppercase), letters.count >= 2 { return true }
        if core.contains(".") { return true }
        if parts.trailing.hasPrefix("."), core.count <= maximumAbbreviationLetters, core.allSatisfy(\.isLetter) {
            return true
        }

        if dictionary.knows(core) { return true }

        // Hyphenated line break ("Glo-" + "balen"): the joined word, or the part before the hyphen.
        if parts.trailing.hasPrefix("-") {
            if let nextLineStart {
                let continuation = splitPunctuation(nextLineStart).core
                if !continuation.isEmpty, dictionary.knows(core + continuation.lowercased()) { return true }
            }
            if core.count < 4 || dictionary.knows(core) { return true }
            // A fragment completed by a following word: a continuation on a later line ("Atmo-" … "sphäre") or the
            // shared last part of an enumeration ("Atmo-, Hydro- und Biosphäre").
            return following.contains { completes(fragment: core, with: $0, dictionary: dictionary) }
        }
        // Continuation of a hyphenated line break.
        if let previousLineEnd {
            let previous = splitPunctuation(previousLineEnd)
            if previous.trailing.hasPrefix("-"), !previous.core.isEmpty,
               dictionary.knows(previous.core + core.lowercased()) {
                return true
            }
        }
        // Compounds and alternatives ("Erde-Mensch", "Tiere/Pflanzen"): every part known.
        let pieces = core.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "–" }).map(String.init)
        if pieces.count > 1, pieces.allSatisfy({ $0.count <= 1 || dictionary.knows($0) }) { return true }
        return false
    }

    /// Whether `fragment` plus `word` (a continuation) or plus a last part of `word` with at least 4 letters (the
    /// shared part of an enumeration) is a known word.
    static func completes(fragment: String, with word: String, dictionary: Lexicon) -> Bool {
        let core = Array(splitPunctuation(word).core)
        guard core.count >= 3, core.allSatisfy(\.isLetter) else { return false }
        if dictionary.knows(fragment + String(core).lowercased()) { return true }
        guard core.count > 4 else { return false }
        for start in 1...(core.count - 4)
        where dictionary.knowsSimple(fragment + String(core[start...]).lowercased()) {
            return true
        }
        return false
    }

    /// Splits a token into leading punctuation, core and trailing punctuation ("„System" → "„", "System", "").
    public static func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        let characters = Array(token)
        var start = 0, end = characters.count
        while start < end, isPunctuation(characters[start]) { start += 1 }
        while end > start, isPunctuation(characters[end - 1]) { end -= 1 }
        return (String(characters[0..<start]), String(characters[start..<end]), String(characters[end...]))
    }

    private static let punctuation: CharacterSet = .punctuationCharacters.union(.symbols)

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(punctuation.contains)
    }

    /// Spell checker plus subject terms, with the capitalization variants a handwritten word may need. Answers are
    /// memoized for the lifetime of the lexicon (one review); the checker's own answers are cached by
    /// `CachingSpellChecker`.
    struct Lexicon {
        let checker: any SpellChecking
        let terms: Set<String>
        private let memo = Memo()

        init(checker: any SpellChecking, terms: Set<String>) {
            self.checker = checker
            self.terms = Set(terms.map(WordReview.lowered))
        }

        /// Results per word, for one review (single-threaded use).
        private final class Memo {
            var known: [String: Bool] = [:]
            var simple: [String: Bool] = [:]
        }

        /// Known word: subject term, dictionary word (also with the first letter lowercased, for sentence starts, or
        /// uppercased for nouns written in lowercase, the latter only from 4 letters on), or a compound of known words.
        func knows(_ word: String) -> Bool {
            if let known = memo.known[word] { return known }
            var budget = Self.maximumSplitAttempts
            let known = knowsSimple(word)
                || (Self.compoundLengths.contains(word.count) && knowsCompound(word, depth: 2, budget: &budget))
            memo.known[word] = known
            return known
        }

        func knowsSimple(_ word: String) -> Bool {
            if let known = memo.simple[word] { return known }
            let known = lookUp(word)
            memo.simple[word] = known
            return known
        }

        private func lookUp(_ word: String) -> Bool {
            if !terms.isEmpty, terms.contains(WordReview.lowered(word)) { return true }
            if checker.isKnown(word) { return true }
            guard let first = word.first else { return false }
            let rest = word.dropFirst()
            let lowerFirst = String(first).lowercased() + rest
            if lowerFirst != word, checker.isKnown(lowerFirst) { return true }
            if word.count >= 4 {
                let upperFirst = String(first).uppercased() + rest
                if upperFirst != word, checker.isKnown(upperFirst) { return true }
            }
            return false
        }

        /// Minimum length of each part of a compound ("Boden|bildungs|prozesse").
        static let minimumPart = 4
        /// Longest last part tried; limits the splits per word (at most 12 for a 30-letter word).
        static let maximumTail = 15
        /// Words checked as compounds (shorter ones cannot have two parts, longer ones are no real words).
        static let compoundLengths = 8...30
        /// Splits tried per word, including the splits of its head.
        static let maximumSplitAttempts = 24
        /// Linking elements between the parts of a German compound ("Bildung|s|prozesse").
        static let linkingElements = ["s", "es", "n", "en"]

        /// German compound the dictionary does not list ("Ressourcenverbrauch"): a known head (possibly itself a
        /// compound, possibly with a linking element) and a known last part (4 to 15 letters, longest first).
        func knowsCompound(_ word: String, depth: Int, budget: inout Int) -> Bool {
            let characters = Array(word)
            let minimum = Self.minimumPart
            guard depth > 0, budget > 0, characters.count >= 2 * minimum, characters.allSatisfy(\.isLetter) else {
                return false
            }
            let first = max(minimum, characters.count - Self.maximumTail)
            for split in first...(characters.count - minimum) {
                guard budget > 0 else { return false }
                budget -= 1
                let tail = characters[split...]
                guard knowsSimple(String(tail.prefix(1)).uppercased() + String(tail.dropFirst())) else { continue }
                let head = String(characters[..<split])
                if knowsSimple(head) || knowsCompound(head, depth: depth - 1, budget: &budget) { return true }
                for link in Self.linkingElements where head.hasSuffix(link) {
                    let stem = String(head.dropLast(link.count))
                    if stem.count >= minimum,
                       knowsSimple(stem) || knowsCompound(stem, depth: depth - 1, budget: &budget) { return true }
                }
            }
            return false
        }
    }

    /// German locale, created once (lowercasing runs for every word of every review).
    static let german = WordTokenizer.german

    static func lowered(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased(with: german)
    }


    // MARK: Context and replacement

    /// Up to `radius` words before and after a word, across the neighbouring lines (reading order). For the
    /// on-device model's suggestions.
    public static func context(
        of wordIndex: Int, in lineID: UUID, lines: [RecognizedLine], radius: Int = 8
    ) -> (before: String, after: String) {
        let ordered = lines.sorted { $0.order < $1.order }
        var flat: [(line: UUID, index: Int, text: String)] = []
        for line in ordered {
            for token in tokens(of: line) { flat.append((line.id, token.index, token.text)) }
        }
        guard let position = flat.firstIndex(where: { $0.line == lineID && $0.index == wordIndex }) else {
            return ("", "")
        }
        let count = max(0, radius)
        let before = flat[max(0, position - count)..<position].map(\.text)
        let after = flat[(position + 1)..<min(flat.count, position + 1 + count)].map(\.text)
        return (before.joined(separator: " "), after.joined(separator: " "))
    }

    /// The line text with one word replaced. Punctuation around the original word stays ("„Sistem" → "„System")
    /// unless the replacement brings its own at that end. An empty replacement removes the word.
    public static func replacing(wordIndex: Int, in line: RecognizedLine, with newText: String) -> String {
        let tokens = WordTokenizer.tokens(in: line.text)
        guard tokens.indices.contains(wordIndex) else { return line.text }
        let token = tokens[wordIndex]
        let replacement = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = line.text
        guard !replacement.isEmpty else {
            // Remove the word and one neighbouring space.
            var range = token.range
            if range.upperBound < text.endIndex, text[range.upperBound].isWhitespace {
                range = range.lowerBound..<text.index(after: range.upperBound)
            } else if range.lowerBound > text.startIndex,
                      text[text.index(before: range.lowerBound)].isWhitespace {
                range = text.index(before: range.lowerBound)..<range.upperBound
            }
            text.removeSubrange(range)
            return text
        }
        let original = splitPunctuation(token.original)
        let own = splitPunctuation(replacement)
        let leading = own.leading.isEmpty ? original.leading : ""
        let trailing = own.trailing.isEmpty ? original.trailing : ""
        text.replaceSubrange(token.range, with: leading + replacement + trailing)
        return text
    }

    // MARK: Suggestions

    /// The word at the same position in the recognizer's alternative readings of the line (only alternatives with
    /// the same number of words), without punctuation and without the word itself.
    public static func lineCandidateWords(line: RecognizedLine, wordIndex: Int) -> [String] {
        let tokens = WordTokenizer.tokens(in: line.text)
        guard tokens.indices.contains(wordIndex) else { return [] }
        let original = splitPunctuation(tokens[wordIndex].original).core
        var result: [String] = []
        for candidate in line.candidates {
            let other = WordTokenizer.tokens(in: candidate)
            guard other.count == tokens.count else { continue }
            let word = splitPunctuation(other[wordIndex].original).core
            if !word.isEmpty, word != original, !result.contains(word) { result.append(word) }
        }
        return result
    }

    /// Subject terms close to the word (Damerau-Levenshtein distance ≤ max(1, length / 4), case-insensitive),
    /// closest first.
    public static func similarTerms(word: String, terms: Set<String>, limit: Int = 5) -> [String] {
        let core = lowered(splitPunctuation(word).core)
        guard !core.isEmpty, limit > 0 else { return [] }
        let maximum = max(1, core.count / 4)
        var scored: [(term: String, distance: Int)] = []
        for term in terms {
            let lower = lowered(term)
            guard lower != core, abs(lower.count - core.count) <= maximum else { continue }
            let distance = editDistance(Array(core), Array(lower))
            if distance <= maximum { scored.append((term, distance)) }
        }
        scored.sort { ($0.distance, $0.term) < ($1.distance, $1.term) }
        return Array(scored.prefix(limit).map(\.term))
    }

    /// Combines suggestion lists in priority order: trims, drops empty entries and the original word, removes
    /// duplicates case-insensitively (the first spelling wins), at most `limit`.
    public static func mergeSuggestions(_ lists: [[String]], original: String, limit: Int = 8) -> [String] {
        let originalCore = splitPunctuation(original.trimmingCharacters(in: .whitespacesAndNewlines)).core
        var seen: Set<String> = []
        var result: [String] = []
        for suggestion in lists.joined() {
            let value = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != originalCore, value != original else { continue }
            guard seen.insert(lowered(value)).inserted else { continue }
            result.append(value)
            if result.count >= limit { break }
        }
        return result
    }

    /// Suggestions without a model: subject terms, the recognizer's alternatives, then the spell checker's guesses.
    public static func localSuggestions(
        line: RecognizedLine, wordIndex: Int, checker: any SpellChecking, terms: Set<String> = [], limit: Int = 8
    ) -> [String] {
        let tokens = WordTokenizer.tokens(in: line.text)
        guard tokens.indices.contains(wordIndex) else { return [] }
        let word = splitPunctuation(tokens[wordIndex].original).core
        guard !word.isEmpty else { return [] }
        return mergeSuggestions(
            [similarTerms(word: word, terms: terms), lineCandidateWords(line: line, wordIndex: wordIndex),
             checker.guesses(for: word)],
            original: word, limit: limit)
    }

    /// Optimal string alignment distance (Damerau-Levenshtein with adjacent transpositions).
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
