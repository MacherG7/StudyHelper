import Foundation
import StudyCore
import StudyData

/// Word-level review of one page (`WordReview`): which words are marked, which lines are illegible, and the
/// open count shown in headers and badges. Built from the stored lines, so views cache it with `DerivedValue`.
struct PageWordReview: Equatable {
    var result = WordReview.Result()
    /// All tokens of the lines that have marks (for the word frames and chips).
    var tokens: [UUID: [ReviewToken]] = [:]

    init() {}

    init(
        lines: [RecognizedLine], method: RecognitionMethod?, terms: Set<String>,
        checker: any SpellChecking = AppSpellChecker.shared
    ) {
        result = WordReview.review(lines, checker: checker, terms: terms) { Self.isEmbeddedLine($0, method: method) }
        for line in lines where result.marks[line.id] != nil { tokens[line.id] = WordReview.tokens(of: line) }
    }

    /// Lines taken from the embedded PDF text or a typed text box are exact: they are never marked. Decided by the
    /// line's stored origin (D-044); lines of older digitizations without an origin are spell-checked like handwriting
    /// (typed text passes anyway). `method` is kept for the cache key only.
    static func isEmbeddedLine(_ line: RecognizedLine, method: RecognitionMethod?) -> Bool {
        WordReview.isEmbedded(line)
    }

    /// The review of a stored page, from the shared memo (`PageWordReviewCache`): only a page whose lines, subject
    /// terms, recognition method or spell checker changed is computed again. Falls back to a plain computation for
    /// checkers without a stable identity.
    static func cached(
        digitization: Digitization, lines: [RecognizedLine], terms: Set<String>,
        checker: any SpellChecking = AppSpellChecker.shared, cache: PageWordReviewCache = .shared
    ) -> PageWordReview {
        let method = digitization.metadata.method
        guard let key = PageWordReviewCache.Key(
            digitizationID: digitization.id, lines: lines, terms: terms, method: method, checker: checker)
        else { return PageWordReview(lines: lines, method: method, terms: terms, checker: checker) }
        if let hit = cache.value(for: key) { return hit }
        let review = PageWordReview(lines: lines, method: method, terms: terms, checker: checker)
        cache.store(review, for: key)
        return review
    }

    var openWords: Int { result.marks.values.reduce(0) { $0 + $1.count } }
    var illegible: Int { result.illegibleLines.count }
    /// Marked words plus illegible lines (the value of the open count).
    var open: Int { result.openCount }

    func isMarked(_ lineID: UUID) -> Bool { result.marks[lineID] != nil }
    func isIllegible(_ lineID: UUID) -> Bool { result.illegibleLines.contains(lineID) }
    /// Marked or illegible.
    func isOpen(_ lineID: UUID) -> Bool { isMarked(lineID) || isIllegible(lineID) }

    /// The marked tokens of a line, in reading order.
    func markedTokens(of lineID: UUID) -> [ReviewToken] {
        guard let marks = result.marks[lineID], let all = tokens[lineID] else { return [] }
        return all.filter { marks.contains($0.index) }
    }

    /// "3 Wörter und 1 unleserliche Stelle" (without "Noch" and "offen").
    static func description(words: Int, illegible: Int) -> String {
        var parts: [String] = []
        if words > 0 { parts.append(words == 1 ? "1 Wort" : "\(words) Wörter") }
        if illegible > 0 { parts.append(illegible == 1 ? "1 unleserliche Stelle" : "\(illegible) unleserliche Stellen") }
        return parts.joined(separator: " und ")
    }

    /// "Noch 3 Wörter und 1 unleserliche Stelle offen".
    static func headline(words: Int, illegible: Int) -> String {
        "Noch \(description(words: words, illegible: illegible)) offen"
    }
}

/// Review state of one page, read from its current digitization. Reading decodes the stored JSON blobs,
/// so views cache it with `DerivedValue`.
struct PageSummary: Equatable {
    /// Words and illegible lines that still need the user's attention (0 if the data is unreadable).
    var open = 0
    /// Marked words (part of `open`).
    var openWords = 0
    /// Illegible lines (part of `open`).
    var illegible = 0
    /// A stored blob of the current digitization cannot be read; the page must not count as "geprüft".
    var unreadable = false

    init(_ source: Source, checker: any SpellChecking = AppSpellChecker.shared) {
        guard let digitization = source.currentDigitization else { return }
        if digitization.hasUnreadableData {
            unreadable = true
        } else {
            let review = PageWordReview.cached(
                digitization: digitization, lines: digitization.lines,
                terms: Set(source.batch?.subject?.confirmedTerms ?? []), checker: checker)
            open = review.open
            openWords = review.openWords
            illegible = review.illegible
        }
    }
}

/// Counts for one import (row in the subject screen).
struct BatchSummary: Equatable {
    var pages = 0
    var open = 0
    var openWords = 0
    var illegible = 0
    var unreadablePages = 0
    var waiting = 0
    var failed = 0

    init(_ batch: ImportBatch, checker: any SpellChecking = AppSpellChecker.shared) {
        let sources = batch.sources
        pages = sources.count
        for source in sources {
            let page = PageSummary(source, checker: checker)
            open += page.open
            openWords += page.openWords
            illegible += page.illegible
            if page.unreadable { unreadablePages += 1 }
            switch source.digitizationState {
            case .pending: waiting += 1
            case .failed: failed += 1
            default: break
            }
        }
    }
}

/// Counts for one subject (row in the subject list).
struct SubjectSummary: Equatable {
    var imports = 0
    var open = 0
    var openWords = 0
    var illegible = 0
    var unreadablePages = 0

    init(_ subject: Subject, checker: any SpellChecking = AppSpellChecker.shared) {
        imports = subject.imports.count
        for batch in subject.imports {
            for source in batch.sources {
                let page = PageSummary(source, checker: checker)
                open += page.open
                openWords += page.openWords
                illegible += page.illegible
                if page.unreadable { unreadablePages += 1 }
            }
        }
    }
}


// MARK: - Memo

/// Identifies spell checkers that can be told apart, so that a stored review is only reused with the same
/// checker. Reference types are identified by object; value types conform to this protocol (or are not memoized).
nonisolated protocol SpellCheckerIdentifying {
    var cacheIdentity: AnyHashable { get }
}

/// Memo of the word review per page, bounded (least recently used pages are dropped). Subject lists and
/// imports recompute the review of every page whenever anything changes; with the memo only changed pages cost
/// anything. Used on the main actor (the lock keeps it safe if that ever changes).
final class PageWordReviewCache {
    static let shared = PageWordReviewCache()

    /// Everything the review of a page depends on.
    struct Key: Hashable {
        let digitizationID: UUID
        let linesHash: Int
        let termsHash: Int
        let method: RecognitionMethod?
        let checker: AnyHashable

        init?(
            digitizationID: UUID, lines: [RecognizedLine], terms: Set<String>, method: RecognitionMethod?,
            checker: any SpellChecking
        ) {
            if let identified = checker as? any SpellCheckerIdentifying {
                self.checker = identified.cacheIdentity
            } else if type(of: checker) is AnyClass {
                self.checker = ObjectIdentifier(checker as AnyObject)
            } else {
                return nil
            }
            self.digitizationID = digitizationID
            var hasher = Hasher()
            hasher.combine(lines)
            linesHash = hasher.finalize()
            termsHash = terms.hashValue
            self.method = method
        }
    }

    private struct Entry {
        var review: PageWordReview
        var tick: Int
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var tick = 0

    init(capacity: Int = 500) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { lock.withLock { entries.count } }

    func value(for key: Key) -> PageWordReview? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            tick += 1
            entry.tick = tick
            entries[key] = entry
            return entry.review
        }
    }

    func store(_ review: PageWordReview, for key: Key) {
        lock.withLock {
            tick += 1
            entries[key] = Entry(review: review, tick: tick)
            guard entries.count > capacity else { return }
            // Drop the least recently used tenth in one go, so that eviction does not run on every insert.
            let drop = max(entries.count - capacity, capacity / 10)
            for (staleKey, _) in entries.sorted(by: { $0.value.tick < $1.value.tick }).prefix(drop) {
                entries[staleKey] = nil
            }
        }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }
}
