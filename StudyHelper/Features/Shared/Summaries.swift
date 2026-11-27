import Foundation
import StudyCore
import StudyData

/// Word-level review of one page (`WordReview`): which words are marked, which lines are illegible, and the
/// open count shown in headers and badges. Built from the stored lines, so views cache it with `DerivedValue`.
nonisolated struct PageWordReview: Equatable, Sendable {
    var result = WordReview.Result()
    /// All tokens of the lines that have marks (for the word frames and chips).
    var tokens: [UUID: [ReviewToken]] = [:]

    init() {}

    init(
        lines: [RecognizedLine], method: RecognitionMethod?, terms: Set<String>,
        checker: any SpellChecking
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
    @MainActor
    static func cached(
        digitization: Digitization, lines: [RecognizedLine], terms: Set<String>,
        checker: any SpellChecking = AppSpellChecker.shared, cache: PageWordReviewCache = .shared
    ) -> PageWordReview {
        cached(
            digitizationID: digitization.id, lines: lines, terms: terms, method: digitization.metadata.method,
            checker: checker, cache: cache)
    }

    /// Same, from plain values: usable off the main actor (`PageSummary(input:checker:)`).
    static func cached(
        digitizationID: UUID, lines: [RecognizedLine], terms: Set<String>, method: RecognitionMethod?,
        checker: any SpellChecking, cache: PageWordReviewCache = .shared
    ) -> PageWordReview {
        guard let key = PageWordReviewCache.Key(
            digitizationID: digitizationID, lines: lines, terms: terms, method: method, checker: checker)
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

/// Everything the review count of one page depends on, as plain values: read from the models on the main actor
/// (`init(_ source:)`), then handed to a background task. Reading decodes the stored JSON blobs.
nonisolated struct PageReviewInput: Sendable {
    var digitizationID: UUID?
    var lines: [RecognizedLine] = []
    var terms: Set<String> = []
    var method: RecognitionMethod?
    /// A stored blob of the current digitization cannot be read.
    var unreadable = false
    var state: DigitizationState = .pending

    init() {}

    @MainActor
    init(_ source: Source) {
        state = source.digitizationState
        guard let digitization = source.currentDigitization else { return }
        digitizationID = digitization.id
        if digitization.hasUnreadableData {
            unreadable = true
        } else {
            // Same order as the review screen reads them, so that both share one memo entry.
            lines = digitization.lines.sorted { $0.order < $1.order }
            terms = Set(source.batch?.subject?.confirmedTerms ?? [])
            method = digitization.metadata.method
        }
    }
}

/// Review state of one page, read from its current digitization. Reading decodes the stored JSON blobs,
/// so views cache it with `DerivedValue`.
nonisolated struct PageSummary: Equatable, Sendable {
    /// Words and illegible lines that still need the user's attention (0 if the data is unreadable).
    var open = 0
    /// Marked words (part of `open`).
    var openWords = 0
    /// Illegible lines (part of `open`).
    var illegible = 0
    /// A stored blob of the current digitization cannot be read; the page must not count as "geprüft".
    var unreadable = false
    var state: DigitizationState = .pending

    init() {}

    /// Computes the review (word marks) of the page: heavy, so run it off the main actor for many pages. The result
    /// is memoized in `PageWordReviewCache.shared`, so that opening the page afterwards does not compute it again.
    init(input: PageReviewInput, checker: any SpellChecking) {
        state = input.state
        guard let digitizationID = input.digitizationID else { return }
        if input.unreadable {
            unreadable = true
        } else {
            let review = PageWordReview.cached(
                digitizationID: digitizationID, lines: input.lines, terms: input.terms, method: input.method,
                checker: checker)
            open = review.open
            openWords = review.openWords
            illegible = review.illegible
        }
    }

    /// Synchronous variant on the main actor (tests, small amounts). Screens use `PageSummaryLoader` instead.
    @MainActor
    init(_ source: Source, checker: any SpellChecking = AppSpellChecker.shared) {
        self.init(input: PageReviewInput(source), checker: checker)
    }
}

/// Counts for one import (row in the subject screen). `pages`, `waiting` and `failed` are cheap and always exact;
/// the open counts come from the reviewed pages (`reviewed`), zero while those are not computed yet.
struct BatchSummary: Equatable {
    var pages = 0
    var open = 0
    var openWords = 0
    var illegible = 0
    var unreadablePages = 0
    var waiting = 0
    var failed = 0

    init(_ batch: ImportBatch, reviewed: [PageSummary]) {
        let sources = batch.sources
        pages = sources.count
        for source in sources {
            switch source.digitizationState {
            case .pending: waiting += 1
            case .failed: failed += 1
            default: break
            }
        }
        for page in reviewed {
            open += page.open
            openWords += page.openWords
            illegible += page.illegible
            if page.unreadable { unreadablePages += 1 }
        }
    }

    /// Computes everything synchronously (tests).
    init(_ batch: ImportBatch, checker: any SpellChecking = AppSpellChecker.shared) {
        self.init(batch, reviewed: batch.sources.map { PageSummary($0, checker: checker) })
    }
}

/// Counts for one subject (row in the subject list).
struct SubjectSummary: Equatable {
    var imports = 0
    var open = 0
    var openWords = 0
    var illegible = 0
    var unreadablePages = 0

    init(_ subject: Subject, reviewed: [PageSummary]) {
        imports = subject.imports.count
        for page in reviewed {
            open += page.open
            openWords += page.openWords
            illegible += page.illegible
            if page.unreadable { unreadablePages += 1 }
        }
    }

    /// Computes everything synchronously (tests).
    init(_ subject: Subject, checker: any SpellChecking = AppSpellChecker.shared) {
        self.init(subject, reviewed: subject.imports.flatMap(\.sources).map { PageSummary($0, checker: checker) })
    }
}

// MARK: - Off the main actor

/// Computes the review counts of a list of pages without blocking the main actor (D-044, launch fix): the first render
/// shows placeholders; the pages are read from the models one at a time (yielding in between), the word review
/// runs on a background executor, and the result is published when it is ready. Any change of what was read (a
/// correction, a new term, a new recognition) starts a new round. Cancelled with the view's task.
///
/// Why: `SubjectSummary` used to run in the first render of the subject list. For every page of every subject it
/// decoded the stored lines and ran the word review with `UITextChecker` on the main thread (about 24 dictionary
/// lookups for each unknown compound word) — 17 imported pages took ~20 s of white screen.
@MainActor
@Observable
final class PageSummaryLoader {
    /// The summaries in the order of the sources; nil until the first round has finished.
    private(set) var pages: [PageSummary]?
    /// Possible subject terms of all the pages (`AppTermSuggestions`), when `run` was asked for them; nil until computed.
    private(set) var termCandidates: [String]?
    /// Rounds finished so far (tests wait for it).
    private(set) var rounds = 0

    /// Remembers that something read during a round changed.
    private nonisolated final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Runs until cancelled.
    /// - Parameters:
    ///   - sources: reads the pages (relationship reads are tracked).
    ///   - checker: the spell checker of the review.
    ///   - suggestTerms: also look for possible subject terms in all the pages.
    func run(sources: @MainActor () -> [Source], checker: any SpellChecking, suggestTerms: Bool = false) async {
        let termProvider = suggestTerms ? AppTermSuggestions.provider : nil
        while !Task.isCancelled {
            let flag = ChangeFlag()
            let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let onChange: @Sendable () -> Void = { flag.set(); continuation.yield() }
            let list = withObservationTracking({ sources() }, onChange: onChange)
            var inputs: [PageReviewInput] = []
            for source in list {
                if flag.isSet || Task.isCancelled { break }
                inputs.append(withObservationTracking({ PageReviewInput(source) }, onChange: onChange))
                await Task.yield()
            }
            if Task.isCancelled { return }
            guard !flag.isSet else { continue }
            let result = await Self.compute(inputs, checker: checker)
            if Task.isCancelled { return }
            if pages != result { pages = result }
            if let termProvider {
                let terms = await Self.suggestTerms(inputs, checker: checker, provider: termProvider)
                if Task.isCancelled { return }
                if termCandidates != terms { termCandidates = terms }
            }
            rounds += 1
            // Wait for the next change, then let a burst of changes settle.
            var iterator = changes.makeAsyncIterator()
            guard await iterator.next() != nil else { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    @concurrent
    private static func suggestTerms(
        _ inputs: [PageReviewInput], checker: any SpellChecking, provider: AppTermSuggestions.Provider
    ) async -> [String] {
        provider(inputs.flatMap(\.lines), CachingSpellChecker(checker), inputs.first?.terms ?? [])
    }

    @concurrent
    private static func compute(_ inputs: [PageReviewInput], checker: any SpellChecking) async -> [PageSummary] {
        var result: [PageSummary] = []
        result.reserveCapacity(inputs.count)
        for input in inputs {
            if Task.isCancelled { break }
            result.append(PageSummary(input: input, checker: checker))
        }
        return result
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
/// anything. Used from the main actor and from background summaries (the lock keeps it safe).
nonisolated final class PageWordReviewCache: @unchecked Sendable {
    static let shared = PageWordReviewCache()

    /// Everything the review of a page depends on.
    nonisolated struct Key: Hashable {
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

    private nonisolated struct Entry {
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
