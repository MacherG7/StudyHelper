import Foundation

// Reading suggestions for one marked word of the word review (D-044, D-046): the word is read again from the ink
// (`VisionWordCandidateProvider` in StudyImport), the readings are ranked here (consensus of several readings plus
// local suggestions), and an optional on-device model may only reorder the best of them.

/// Where a suggestion came from.
public enum WordCandidateSource: String, Sendable, Hashable, Codable {
    /// Read again from the ink or image of the word or its line.
    case vision
    /// A subject term close to the written word.
    case term
    /// A guess of the spell checker.
    case spelling
    /// The word at the same position in the recognizer's alternative readings of the line.
    case lineAlternative
    /// Moved up or down by the on-device model (it may only reorder the given candidates).
    case model
}

/// One reading suggestion for a marked word.
public struct WordCandidate: Sendable, Hashable {
    public var text: String
    /// 0…1, relative to the best candidate of the same list.
    public var score: Double
    public var sources: Set<WordCandidateSource>
    /// How many readings of the ink (Vision passes) found this word among their first candidates.
    public var readings: Int

    public init(text: String, score: Double, sources: Set<WordCandidateSource>, readings: Int = 0) {
        self.text = text
        self.score = score
        self.sources = sources
        self.readings = readings
    }
}

/// The result of reading one marked word again (D-046, D-047).
public struct WordRereadResult: Sendable, Hashable {
    /// Plausible suggestions, best first (`WordCandidateRanking.plausible`); never the written word itself.
    public var candidates: [WordCandidate]
    /// The readings of the ink agree with the written word (`WordCandidateRanking.isConfirmed`): the recognizer read
    /// it the same way again, so it is most likely what the writer wrote. Demotes spelling marks (D-047).
    public var readingConfirmed: Bool
    /// Diagnostics for measurements (`word-review-bench`): the cleaned candidates of each reading of the ink …
    public var readings: [[String]]
    /// … and the ranked candidates before the plausibility filter.
    public var ranked: [WordCandidate]

    public init(
        candidates: [WordCandidate] = [], readingConfirmed: Bool = false, readings: [[String]] = [],
        ranked: [WordCandidate] = []
    ) {
        self.candidates = candidates
        self.readingConfirmed = readingConfirmed
        self.readings = readings
        self.ranked = ranked
    }
}

// MARK: - Geometry

/// Rows of handwriting: recognized word boxes are often taller than the distance between two rows, so a frame or crop
/// of the plain box shows parts of the rows above and below.
public enum WordGeometry {
    /// Lines whose centres are closer than this fraction of the (smaller) line height are on the same row.
    static let sameRowFraction = 0.3

    /// Distances from the row centre to the centres of the nearest rows above and below that overlap the given
    /// horizontal range (nil: no such row).
    static func neighbourDistances(
        centre: Double, xRange: ClosedRange<Double>, line: RecognizedLine, pageLines: [RecognizedLine]
    ) -> (up: Double?, down: Double?) {
        var up: Double?, down: Double?
        for other in pageLines where other.id != line.id && !other.rect.isEmpty {
            guard other.rect.maxX > xRange.lowerBound, other.rect.minX < xRange.upperBound else { continue }
            guard !other.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let delta = other.rect.midY - centre
            let sameRow = sameRowFraction * max(min(line.rect.height, other.rect.height), 0.0001)
            if abs(delta) < sameRow { continue }
            if delta < 0 { up = min(up ?? .infinity, -delta) } else { down = min(down ?? .infinity, delta) }
        }
        return (up, down)
    }

    /// The word box clamped to its row band: the row centre (`line.rect.midY`) ± half the distance to the
    /// neighbouring rows (rows of `pageLines` that overlap the word horizontally). Without neighbours that side keeps
    /// the word box. Used for the frame around a word and for crops of it.
    public static func bandRect(
        for wordRect: NormalizedRect, line: RecognizedLine, pageLines: [RecognizedLine]
    ) -> NormalizedRect {
        guard !wordRect.isEmpty else { return wordRect }
        let centre = line.rect.isEmpty ? wordRect.midY : line.rect.midY
        let reach = wordRect.width / 2
        let neighbours = neighbourDistances(
            centre: centre, xRange: (wordRect.minX - reach)...(wordRect.maxX + reach), line: line,
            pageLines: pageLines)
        var top = wordRect.minY, bottom = wordRect.maxY
        if let up = neighbours.up { top = max(top, centre - up / 2) }
        if let down = neighbours.down { bottom = min(bottom, centre + down / 2) }
        guard bottom > top, top != wordRect.minY || bottom != wordRect.maxY else { return wordRect }
        return NormalizedRect(x: wordRect.x, y: top, width: wordRect.width, height: bottom - top)
    }

    /// Vertical range for picking the pen strokes of a word's row: `centre` ± `factor` × `height`, but on each side
    /// at most `pitchShare` of the distance to the neighbouring row.
    public static func strokeBand(
        centre: Double, height: Double, xRange: ClosedRange<Double>, line: RecognizedLine,
        pageLines: [RecognizedLine], factor: Double = 0.7, pitchShare: Double = 0.8
    ) -> ClosedRange<Double> {
        let half = factor * height
        let neighbours = neighbourDistances(centre: centre, xRange: xRange, line: line, pageLines: pageLines)
        let up = neighbours.up.map { min(half, pitchShare * $0) } ?? half
        let down = neighbours.down.map { min(half, pitchShare * $0) } ?? half
        return (centre - up)...(centre + down)
    }
}

// MARK: - Term suggestions

/// Words the user may want to remember as subject terms ("Als Fachbegriff merken"): words the spell checker does not
/// know that repeat on the given pages or stand in a heading-like line.
public enum TermSuggestions {
    public static let maximumCount = 12
    /// A line is heading-like when it has at most this many words and is clearly taller than the usual line.
    static let headingWordCount = 3
    static let headingHeightFactor = 1.6
    /// A word this close (normalized edit distance) to a spelling guess is a misreading, not a term ("Wandeli").
    static let misreadingDistance = 0.15
    /// Endings of German inflection: a guess that only adds or drops one of them is the same term
    /// ("Anthroposphäre" / "Anthroposphären").
    static let inflectionEndings = ["e", "n", "en", "s", "es", "er", "em", "ern", "nen"]

    /// Whether `word` looks like a misreading of the dictionary word `guess`: close to it, but not just another
    /// inflection or a spelling with a space or hyphen ("Aralsee Syndrom").
    static func isMisreading(_ word: String, of guess: String) -> Bool {
        let a = WordReview.lowered(word), b = WordReview.lowered(guess)
        guard WordCandidateRanking.distance(a, b) <= misreadingDistance else { return false }
        let joined: (String) -> String = { $0.filter { $0 != " " && $0 != "-" } }
        if joined(a) == joined(b) { return false }
        for ending in inflectionEndings where a + ending == b || b + ending == a { return false }
        return true
    }

    /// Unknown words (marked by `WordReview` for spelling, with `known` as terms) that occur at least twice or in a
    /// heading-like line (title block, or a line of at most 3 words written clearly larger than the median line),
    /// most frequent first, deduplicated case-insensitively (the most frequent spelling wins), at most
    /// `maximumCount`. A word found only once and one letter away from a spelling guess is left out (a misreading of
    /// a known word, "Wandeli").
    public static func candidates(lines: [RecognizedLine], checker: any SpellChecking, known: Set<String>) -> [String] {
        let checker = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let review = WordReview.review(lines, checker: checker, terms: known)
        let heights = lines.filter { !WordReview.isEmbedded($0) && !$0.rect.isEmpty }.map(\.rect.height).sorted()
        let median = heights.isEmpty ? 0 : heights[heights.count / 2]

        struct Entry { var count = 0; var heading = false; var first = 0; var spellings: [String: Int] = [:] }
        var entries: [String: Entry] = [:]
        var position = 0
        for line in lines.sorted(by: { $0.order < $1.order }) {
            guard let marked = review.marks[line.id] else { continue }
            let tokens = WordReview.tokens(of: line)
            let heading = line.blockKind == .title
                || (tokens.count <= headingWordCount && median > 0 && line.rect.height >= headingHeightFactor * median)
            for index in marked where review.reasons[WordReference(lineID: line.id, wordIndex: index)] == .spelling {
                let core = tokens[index].core
                guard core.filter(\.isLetter).count >= 3,
                      core.allSatisfy({ $0.isLetter || $0 == "-" }) else { continue }
                let key = WordReview.lowered(core)
                var entry = entries[key] ?? Entry(first: position)
                entry.count += 1
                entry.heading = entry.heading || heading
                entry.spellings[core, default: 0] += 1
                entries[key] = entry
                position += 1
            }
        }
        return entries.values
            .filter { $0.count >= 2 || $0.heading }
            .sorted { ($0.count, -$0.first) > ($1.count, -$1.first) }
            .compactMap { entry -> String? in
                guard let word = entry.spellings.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else {
                    return nil
                }
                // A misreading rarely repeats in the same spelling; a single one close to a known word is dropped.
                if entry.count < 2, checker.guesses(for: word).contains(where: { isMisreading(word, of: $0) }) {
                    return nil
                }
                return word
            }
            .prefix(maximumCount)
            .map { $0 }
    }
}

// MARK: - Readings

/// One recognition pass over a crop: its observations left to right, each with candidate strings (best first).
public struct TextReading: Sendable, Hashable {
    public struct Observation: Sendable, Hashable {
        /// Horizontal position in the crop, 0…1.
        public var minX: Double
        public var width: Double
        public var candidates: [String]

        public init(minX: Double, width: Double, candidates: [String]) {
            self.minX = minX
            self.width = width
            self.candidates = candidates
        }
    }

    public var observations: [Observation]

    public init(observations: [Observation]) {
        self.observations = observations.sorted { $0.minX < $1.minX }
    }
}

// MARK: - Ranking

/// Turns readings of a word into ranked suggestions (pure logic; the readings come from Vision or from tests).
public enum WordCandidateRanking {
    /// Which crop a reading came from.
    public enum Crop: Sendable, Hashable { case word, line }

    /// Candidate words of one reading, best first, with the weight of that reading.
    public struct VisionList: Sendable, Hashable {
        public var candidates: [String]
        public var weight: Double
        public var crop: Crop

        public init(candidates: [String], weight: Double, crop: Crop) {
            self.candidates = candidates
            self.weight = weight
            self.crop = crop
        }
    }

    /// Suggestions without reading the ink again (`WordReview.localSuggestions`, split by source).
    public struct LocalLists: Sendable, Hashable {
        public var terms: [String]
        public var lineAlternatives: [String]
        public var spelling: [String]

        public init(terms: [String] = [], lineAlternatives: [String] = [], spelling: [String] = []) {
            self.terms = terms
            self.lineAlternatives = lineAlternatives
            self.spelling = spelling
        }

        /// The local suggestions of the word at `wordIndex` of `line`.
        public static func of(
            line: RecognizedLine, wordIndex: Int, checker: any SpellChecking, terms: Set<String>
        ) -> LocalLists {
            let tokens = WordTokenizer.tokens(in: line.text)
            guard tokens.indices.contains(wordIndex) else { return LocalLists() }
            let word = WordReview.splitPunctuation(tokens[wordIndex].original).core
            guard !word.isEmpty else { return LocalLists() }
            return LocalLists(
                terms: WordReview.similarTerms(word: word, terms: terms),
                lineAlternatives: WordReview.lineCandidateWords(line: line, wordIndex: wordIndex),
                spelling: checker.guesses(for: word))
        }
    }

    // Weights (tuned on a real Goodnotes export with `word-review-bench`).
    static let readingDepth = 5
    static let agreementBonus = 0.35
    static let knownBonus = 0.75
    static let farPenalty = 1.0
    static let termWeight = 0.9
    static let lineAlternativeWeight = 0.5
    static let spellingWeight = 0.45
    /// Closeness filter: normalized edit distance to the written word …
    static let maximumDistanceToWritten = 0.5
    /// … or to a reading of the other crop.
    static let maximumDistanceToReading = 0.34

    // MARK: Candidates from readings

    /// Candidate words from a crop around the word. `wordSpan` is where the word lies in the crop (0…1): the
    /// observation overlapping it most is used, and in multi-word strings the token overlapping it most.
    public static func wordCropCandidates(_ reading: TextReading, wordSpan: ClosedRange<Double>) -> [String] {
        func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
            max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        }
        guard let main = reading.observations.max(by: {
            overlap($0.minX...($0.minX + $0.width), wordSpan) < overlap($1.minX...($1.minX + $1.width), wordSpan)
        }), overlap(main.minX...(main.minX + main.width), wordSpan) > 0 else { return [] }
        var result: [String] = []
        for string in main.candidates {
            let tokens = WordTokenizer.tokens(in: string)
            guard !tokens.isEmpty else { continue }
            let total = Double(max(1, string.count))
            let best = tokens.max { a, b in
                func span(_ t: WordToken) -> ClosedRange<Double> {
                    let start = Double(string.distance(from: string.startIndex, to: t.range.lowerBound)) / total
                    let end = Double(string.distance(from: string.startIndex, to: t.range.upperBound)) / total
                    return (main.minX + start * main.width)...(main.minX + end * main.width)
                }
                return overlap(span(a), wordSpan) < overlap(span(b), wordSpan)
            }
            if let best, let word = clean(best.original), !result.contains(word) { result.append(word) }
        }
        return result
    }

    /// Candidate words from a crop of the whole line: every candidate reading (the widest observation's candidates,
    /// the other observations with their best reading) aligned word by word with the recognized line; the word at
    /// `wordIndex`.
    public static func lineCropCandidates(_ reading: TextReading, line: String, wordIndex: Int) -> [String] {
        let lineTokens = WordTokenizer.tokens(in: line)
        guard lineTokens.indices.contains(wordIndex),
              let mainIndex = reading.observations.indices.max(by: {
                  reading.observations[$0].width < reading.observations[$1].width
              }) else { return [] }
        var result: [String] = []
        for candidate in reading.observations[mainIndex].candidates {
            let joined = reading.observations.enumerated().map { index, observation in
                index == mainIndex ? candidate : (observation.candidates.first ?? "")
            }.joined(separator: " ")
            let tokens = WordTokenizer.tokens(in: joined)
            for step in WordAlignment.align(lineTokens, tokens) {
                switch step {
                case .match(let left, let right) where left == wordIndex,
                     .substitution(let left, let right) where left == wordIndex:
                    if let word = clean(tokens[right].original), !result.contains(word) { result.append(word) }
                default: break
                }
            }
        }
        return result
    }

    /// A candidate word without surrounding punctuation, or nil for garbage: no letters, inner spaces, characters
    /// other than letters, digits, hyphen, apostrophe and period, letters outside Latin-1 (scribbles read as
    /// "ą", "ś" or Cyrillic), mostly non-letters, or two words run together ("SchädiEingrifte").
    public static func clean(_ text: String) -> String? {
        let core = WordReview.splitPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines)).core
        guard !core.isEmpty, !core.contains(where: \.isWhitespace) else { return nil }
        var letters = 0
        var previous: Character?
        for character in core {
            if character.isLetter {
                guard character.unicodeScalars.allSatisfy(isLatinLetter) else { return nil }
                letters += 1
                if character.isUppercase, let previous, previous.isLetter, previous.isLowercase { return nil }
            } else if !(character.isNumber || "-'’.".contains(character)) {
                return nil
            }
            previous = character
        }
        guard letters > 0, Double(letters) >= 0.75 * Double(core.count) else { return nil }
        return core
    }

    /// `clean`, and at least two characters when the written word has two or more (single letters are never words
    /// the review marks).
    static func clean(_ text: String, written: String) -> String? {
        guard let word = clean(text) else { return nil }
        return word.count < 2 && written.count >= 2 ? nil : word
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0xFF, 0x1E9E: true
        default: false
        }
    }

    /// Normalized edit distance (Levenshtein on the lowercased words, by the longer word), 0…1.
    public static func distance(_ a: String, _ b: String) -> Double {
        let x = WordTokenizer.normalize(a), y = WordTokenizer.normalize(b)
        let length = max(x.count, y.count)
        guard length > 0 else { return 0 }
        return Double(WordAlignment.characterDistance(x, y)) / Double(length)
    }

    // MARK: Consensus

    /// Ranks the suggestions for the written word.
    ///
    /// Each reading adds `weight / (rank + 1)` for its first candidates; candidates found by several readings get an
    /// agreement bonus, read candidates the dictionary (or `terms`) knows a bonus, and read candidates far from the
    /// written word a penalty. Local suggestions add less (terms, then line alternatives, then spelling guesses).
    /// Closeness filter: a candidate stays only if its normalized edit distance to the written word is at most 0.5,
    /// or at most 0.34 to a reading of the other crop (word vs. line; for local suggestions any reading). The written
    /// word itself is never returned. Best first, at most `limit`, scores relative to the best.
    public static func rank(
        written: String, vision: [VisionList], local: LocalLists, checker: any SpellChecking,
        terms: Set<String> = [], limit: Int = 8
    ) -> [WordCandidate] {
        let writtenCore = WordReview.splitPunctuation(written.trimmingCharacters(in: .whitespacesAndNewlines)).core
        guard !writtenCore.isEmpty, limit > 0 else { return [] }
        let cached = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let lexicon = WordReview.Lexicon(checker: cached, terms: terms)

        final class Entry {
            var score = 0.0
            var spellings: [String: Double] = [:]
            var sources: Set<WordCandidateSource> = []
            var lists: Set<Int> = []
            var crops: Set<Crop> = []
            var order: Int
            init(order: Int) { self.order = order }
        }
        var entries: [String: Entry] = [:]
        var readingsByCrop: [Crop: Set<String>] = [:]
        func entry(_ word: String) -> Entry {
            let key = WordReview.lowered(word)
            if let existing = entries[key] { return existing }
            let new = Entry(order: entries.count)
            entries[key] = new
            return new
        }

        for (listIndex, list) in vision.enumerated() {
            var seen: Set<String> = []
            for word in list.candidates.compactMap({ clean($0, written: writtenCore) }) where seen.count < readingDepth {
                guard seen.insert(WordReview.lowered(word)).inserted else { continue }
                let value = list.weight / Double(seen.count)
                let e = entry(word)
                e.score += value
                e.spellings[word, default: 0] += value
                e.sources.insert(.vision)
                e.lists.insert(listIndex)
                e.crops.insert(list.crop)
                readingsByCrop[list.crop, default: []].insert(WordReview.lowered(word))
            }
        }
        for e in entries.values {
            e.score += agreementBonus * Double(max(0, e.lists.count - 1))
            let best = e.spellings.max { $0.value < $1.value }?.key ?? ""
            if lexicon.knows(best) { e.score += knownBonus }
            if distance(best, writtenCore) > maximumDistanceToWritten { e.score -= farPenalty }
        }
        let localLists: [([String], Double, WordCandidateSource)] = [
            (local.terms, termWeight, .term), (local.lineAlternatives, lineAlternativeWeight, .lineAlternative),
            (local.spelling, spellingWeight, .spelling),
        ]
        for (words, weight, source) in localLists {
            for (rank, word) in words.compactMap({ clean($0, written: writtenCore) }).prefix(readingDepth).enumerated() {
                let value = weight / Double(rank + 1)
                let e = entry(word)
                e.score += value
                e.spellings[word, default: 0] += value
                e.sources.insert(source)
            }
        }

        let allReadings = readingsByCrop.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var ranked: [(text: String, score: Double, sources: Set<WordCandidateSource>, order: Int, readings: Int)] = []
        for (key, e) in entries {
            let spelling = preferredSpelling(e.spellings, checker: cached, terms: terms)
            guard spelling != writtenCore else { continue }
            // Closeness filter.
            if distance(spelling, writtenCore) > maximumDistanceToWritten {
                let others: Set<String>
                if e.crops.isEmpty {
                    others = allReadings
                } else {
                    others = readingsByCrop.filter { !e.crops.contains($0.key) }
                        .reduce(into: Set<String>()) { $0.formUnion($1.value) }
                }
                guard others.contains(where: { $0 != key && distance($0, key) <= maximumDistanceToReading }) else {
                    continue
                }
            }
            ranked.append((spelling, e.score, e.sources, e.order, e.lists.count))
        }
        ranked.sort { ($0.score, -$0.order) > ($1.score, -$1.order) }
        let top = ranked.prefix(limit)
        let best = max(top.first?.score ?? 1, 0.0001)
        return top.map {
            WordCandidate(
                text: $0.text, score: min(1, max(0, $0.score) / best), sources: $0.sources, readings: $0.readings)
        }
    }

    // MARK: Confirmed reading and plausibility (D-047)

    /// Readings that must read the written word as their first candidate for it to count as confirmed.
    static let confirmingFirstReadings = 2

    /// Whether the readings of the ink confirm the written word (D-047). All of:
    /// - it is the consensus top reading: highest score from the readings alone (rank and agreement, no dictionary
    ///   bonus, which would favour any known neighbour of an unknown but correct term such as "Hydro" → "Hydra");
    /// - at least `confirmingFirstReadings` readings have it as their first candidate;
    /// - no reading has another word that the dictionary or the terms know as its first candidate. A reading that
    ///   prefers a real word ("fasst" for "tasst", "Eingriffe" for "Eingrifte") is the typical sign of a misreading
    ///   that the other passes repeat; on the real export this keeps every such error marked.
    /// Compared case-insensitively, without surrounding punctuation; single letters are no readings of longer words.
    public static func isConfirmed(
        written: String, vision: [VisionList], checker: any SpellChecking, terms: Set<String> = []
    ) -> Bool {
        let writtenCore = WordReview.splitPunctuation(written.trimmingCharacters(in: .whitespacesAndNewlines)).core
        let writtenKey = WordReview.lowered(writtenCore)
        guard !writtenKey.isEmpty else { return false }
        let cached = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let lexicon = WordReview.Lexicon(checker: cached, terms: terms)
        var scores: [String: Double] = [:]
        var lists: [String: Int] = [:]
        var first = 0
        for list in vision {
            var seen: [String] = []
            var firstWord: String?
            for word in list.candidates.compactMap({ clean($0, written: writtenCore) }) where seen.count < readingDepth {
                let key = WordReview.lowered(word)
                guard !seen.contains(key) else { continue }
                if seen.isEmpty { firstWord = word }
                seen.append(key)
                scores[key, default: 0] += list.weight / Double(seen.count)
                lists[key, default: 0] += 1
            }
            guard let firstWord, let firstKey = seen.first else { continue }
            if firstKey == writtenKey {
                first += 1
            } else if WordReview.isKnownWord(firstWord, dictionary: lexicon) {
                return false
            }
        }
        guard first >= confirmingFirstReadings, scores[writtenKey] != nil else { return false }
        let total: (String) -> Double = { (scores[$0] ?? 0) + agreementBonus * Double(max(0, (lists[$0] ?? 0) - 1)) }
        let mine = total(writtenKey)
        return scores.keys.allSatisfy { $0 == writtenKey || total($0) < mine }
    }

    /// Readings that must agree on a top candidate the dictionary does not know for it to be offered.
    static let plausibleReadings = 2

    /// The candidates worth offering: words the dictionary or the subject terms know (also compounds of known parts
    /// and hyphenated words of known pieces), and the best candidate when at least `plausibleReadings` readings of
    /// the ink agree on it (an unknown term such as "Pedosphäre"). Mutations of the written word that are no words
    /// ("Erdeii", "db" for "ab") are dropped. When the written word is itself a real word, a candidate needs a
    /// reading of the ink too (the spell checker's neighbours of a correct word, "dusch" for "durch", are no
    /// readings). At most `limit`, order kept. `allowsUnknownBest` false: only known words (after a confirmed
    /// reading).
    public static func plausible(
        _ candidates: [WordCandidate], written: String? = nil, checker: any SpellChecking, terms: Set<String> = [],
        limit: Int = 5, allowsUnknownBest: Bool = true
    ) -> [WordCandidate] {
        let cached = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let lexicon = WordReview.Lexicon(checker: cached, terms: terms)
        let writtenIsKnown = written.map { WordReview.isKnownWord($0, dictionary: lexicon) } ?? false
        var result: [WordCandidate] = []
        for (index, candidate) in candidates.enumerated() where result.count < max(0, limit) {
            if writtenIsKnown, candidate.readings == 0, !candidate.sources.contains(.term) { continue }
            if WordReview.isKnownWord(candidate.text, dictionary: lexicon)
                || (allowsUnknownBest && index == 0 && candidate.readings >= plausibleReadings) {
                result.append(candidate)
            }
        }
        return result
    }

    /// The spelling to show: one the dictionary or the terms know exactly, else the one with the most weight.
    private static func preferredSpelling(
        _ spellings: [String: Double], checker: any SpellChecking, terms: Set<String>
    ) -> String {
        let ordered = spellings.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        return ordered.first { terms.contains($0) }
            ?? ordered.first { checker.isKnown($0) }
            ?? ordered.first ?? ""
    }

    // MARK: Model reordering

    /// Candidates a model may reorder only when the readings leave a real choice: the best candidate and the words the
    /// dictionary (or the terms) knows whose score is at least this share of the best.
    static let rerankCloseness = 0.6

    /// Positions (ascending, within the first `maximum`) the model may reorder: the best candidate plus known words
    /// scoring at least `rerankCloseness` of it. Fewer than two positions: nothing to ask (the consensus is clear, or
    /// only non-words compete). On a real export the model, given every candidate, preferred non-words and lowered
    /// top-1 from 96 % to 76 %.
    public static func rerankPositions(
        _ candidates: [WordCandidate], checker: any SpellChecking, terms: Set<String>, maximum: Int = 6
    ) -> [Int] {
        guard let best = candidates.first, maximum > 1 else { return [] }
        let cached = checker as? CachingSpellChecker ?? CachingSpellChecker(checker)
        let lexicon = WordReview.Lexicon(checker: cached, terms: terms)
        var positions = [0]
        for (index, candidate) in candidates.prefix(maximum).enumerated().dropFirst()
        where candidate.score >= rerankCloseness * best.score && lexicon.knows(candidate.text) {
            positions.append(index)
        }
        return positions.count > 1 ? positions : []
    }

    /// Applies a model's ordering of the first `count` candidates (see `applyOrder(_:to:positions:)`).
    public static func applyOrder(_ order: [String], to candidates: [WordCandidate], count: Int) -> [WordCandidate] {
        applyOrder(order, to: candidates, positions: Array(0..<min(max(0, count), candidates.count)))
    }

    /// Applies a model's ordering to the candidates at `positions`: only those candidates are taken from `order`
    /// (exact or case-insensitive match; everything else is ignored), the ones the model left out follow in their
    /// previous order, all other candidates keep their place. Candidates that changed place get `.model`; the scores
    /// at `positions` are handed out again in the new order, so the list stays descending.
    public static func applyOrder(
        _ order: [String], to candidates: [WordCandidate], positions: [Int]
    ) -> [WordCandidate] {
        let slots = Array(Set(positions.filter(candidates.indices.contains))).sorted()
        guard slots.count > 1 else { return candidates }
        var picked: [Int] = []
        for answer in order {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let slot = slots.first { candidates[$0].text == trimmed }
                ?? slots.first { WordReview.lowered(candidates[$0].text) == WordReview.lowered(trimmed) }
            if let slot, !picked.contains(slot) { picked.append(slot) }
        }
        guard !picked.isEmpty else { return candidates }
        let newOrder = picked + slots.filter { !picked.contains($0) }
        let scores = slots.map { candidates[$0].score }.sorted(by: >)
        var result = candidates
        for (rank, slot) in slots.enumerated() {
            var candidate = candidates[newOrder[rank]]
            if newOrder[rank] != slot { candidate.sources.insert(.model) }
            candidate.score = scores[rank]
            result[slot] = candidate
        }
        return result
    }

    /// Runs `operation` and returns its result, or nil after `seconds` (or when the calling task is cancelled). The
    /// operation keeps running detached until it finishes but is cancelled; its late result is dropped. Does not wait
    /// for an operation that ignores cancellation.
    public static func value<T: Sendable>(
        within seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                race.install(continuation)
                race.track(Task {
                    let value = await operation()
                    race.finish(value)
                })
                race.track(Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    race.finish(nil)
                })
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// First result wins; later ones are dropped and the remaining tasks cancelled.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var result: T??
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<T?, Never>) {
            let done: T?? = lock.withLock {
                if result == nil { self.continuation = continuation }
                return result
            }
            if let done { continuation.resume(returning: done) }
        }

        func track(_ task: Task<Void, Never>) {
            let finished = lock.withLock { () -> Bool in
                if result != nil { return true }
                tasks.append(task)
                return false
            }
            if finished { task.cancel() }
        }

        func finish(_ value: T?) {
            let (waiting, running): (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) = lock.withLock {
                guard result == nil else { return (nil, []) }
                result = .some(value)
                defer { continuation = nil; tasks = [] }
                return (continuation, tasks)
            }
            waiting?.resume(returning: value)
            running.forEach { $0.cancel() }
        }
    }
}
