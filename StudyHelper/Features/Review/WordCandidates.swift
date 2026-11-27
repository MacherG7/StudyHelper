import Foundation
import Observation
import StudyAI
import StudyCore
import StudyData
import StudyImport

/// Identifies one word to read: the digitization, the line, the word and the text it has now (a corrected word
/// has another text, so its old candidates are not used for it).
nonisolated struct WordKey: Hashable, Sendable {
    var digitizationID: UUID
    var lineID: UUID
    var wordIndex: Int
    var text: String
}

/// Words whose reading the ink confirmed (D-047), readable from any thread: the background summaries
/// (`PageSummary`) leave them out of the open counts. Filled by `WordCandidateCache`.
nonisolated final class ConfirmedReadings: @unchecked Sendable {
    static let shared = ConfirmedReadings()
    private let lock = NSLock()
    private var keys: Set<WordKey> = []
    private let limit: Int

    init(limit: Int = 4_000) {
        self.limit = max(1, limit)
    }

    func contains(_ key: WordKey) -> Bool { lock.withLock { keys.contains(key) } }

    /// Whether the key was new.
    @discardableResult
    func insert(_ key: WordKey) -> Bool {
        lock.withLock {
            if keys.count >= limit { keys.removeAll(keepingCapacity: true) }
            return keys.insert(key).inserted
        }
    }

    func removeAll() { lock.withLock { keys.removeAll() } }
}

/// Readings already computed in this session, per word (`WordKey`). Shared by the page's background computation
/// and the word sheet, so that a word is read once. Bounded: above `limit` entries it starts over.
@MainActor
@Observable
final class WordCandidateCache {
    static let shared = WordCandidateCache(confirmations: .shared)

    /// Raised with every stored entry; views that show a best guess read it and refresh.
    private(set) var revision = 0
    /// Raised only when a word's reading is newly confirmed (D-047): page counts follow it without recomputing
    /// for every stored candidate list.
    private(set) var confirmationRevision = 0
    @ObservationIgnored private var storage: [WordKey: WordRereadResult] = [:]
    @ObservationIgnored private let limit: Int
    @ObservationIgnored let confirmations: ConfirmedReadings

    /// - Parameter confirmations: where confirmed readings go; the app's cache (`shared`) shares them with the
    ///   background summaries, other caches (tests) keep their own.
    init(limit: Int = 4_000, confirmations: ConfirmedReadings? = nil) {
        self.limit = max(1, limit)
        self.confirmations = confirmations ?? ConfirmedReadings(limit: limit)
    }

    var count: Int { storage.count }

    /// nil: not computed yet. An empty list: computed, nothing found.
    func candidates(for key: WordKey) -> [WordCandidate]? {
        result(for: key)?.candidates
    }

    func result(for key: WordKey) -> WordRereadResult? {
        _ = revision
        return storage[key]
    }

    /// Whether the ink confirmed the word as written (false while it was not read yet).
    func isConfirmed(_ key: WordKey) -> Bool {
        _ = confirmationRevision
        return confirmations.contains(key)
    }

    func store(_ candidates: [WordCandidate], for key: WordKey) {
        store(WordRereadResult(candidates: candidates), for: key)
    }

    func store(_ result: WordRereadResult, for key: WordKey) {
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = result
        revision += 1
        if result.readingConfirmed, confirmations.insert(key) { confirmationRevision += 1 }
    }

    func removeAll() {
        storage.removeAll()
        confirmations.removeAll()
        revision += 1
        confirmationRevision += 1
    }

    /// The best candidate that differs from the word as it is written (without punctuation, ignoring case): none
    /// for a confirmed reading. The provider offers only plausible candidates (D-047).
    func bestGuess(for key: WordKey) -> String? {
        guard let result = result(for: key), !result.readingConfirmed else { return nil }
        let current = WordReview.splitPunctuation(key.text).core.lowercased()
        return result.candidates.first { $0.text.lowercased() != current && !$0.text.isEmpty }?.text
    }
}

/// Computes candidates for the marked words of the visible page in the background (low priority, at most
/// `maxConcurrent` at a time) and puts them into the cache. Cancelled when the page is left.
@MainActor
final class WordCandidatePrefetcher {
    struct Job: Sendable {
        var key: WordKey
        var request: WordRereadRequest
    }

    private let cache: WordCandidateCache
    private let provider: any WordCandidateProviding
    private let maxConcurrent: Int
    private var task: Task<Void, Never>?
    /// Words handed to the provider so far (tests).
    private(set) var started = 0

    init(
        cache: WordCandidateCache = .shared, provider: any WordCandidateProviding = AppWordCandidates.provider,
        maxConcurrent: Int = 2
    ) {
        self.cache = cache
        self.provider = provider
        self.maxConcurrent = max(1, maxConcurrent)
    }

    var isRunning: Bool { task != nil }

    /// Starts (replacing a running computation); words that are cached are skipped.
    func start(_ jobs: [Job]) {
        cancel()
        let pending = jobs.filter { cache.result(for: $0.key) == nil }
        guard !pending.isEmpty else { return }
        let provider = provider
        let limit = maxConcurrent
        task = Task(priority: .utility) { [self] in
            await Self.run(pending, provider: provider, limit: limit) {
                await self.markStarted()
            } store: { key, result in
                await self.store(result, for: key)
            }
            await finish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits until the running computation has finished (tests).
    func waitUntilIdle() async {
        await task?.value
    }

    private func markStarted() { started += 1 }

    private func store(_ result: WordRereadResult, for key: WordKey) {
        cache.store(result, for: key)
    }

    private func finish() { task = nil }

    nonisolated private static func run(
        _ jobs: [Job], provider: any WordCandidateProviding, limit: Int,
        started: @escaping @Sendable () async -> Void,
        store: @escaping @Sendable (WordKey, WordRereadResult) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            var running = 0
            while running < limit, !Task.isCancelled, let job = iterator.next() {
                group.addTask(priority: .utility) { await compute(job, provider, started, store) }
                running += 1
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let job = iterator.next() else { continue }
                group.addTask(priority: .utility) { await compute(job, provider, started, store) }
            }
        }
    }

    nonisolated private static func compute(
        _ job: Job, _ provider: any WordCandidateProviding,
        _ started: @Sendable () async -> Void, _ store: @Sendable (WordKey, WordRereadResult) async -> Void
    ) async {
        if Task.isCancelled { return }
        await started()
        let result = try? await provider.reread(for: job.request)
        // A cancelled word is not stored: it is computed again when the page is shown again.
        if Task.isCancelled { return }
        await store(job.key, result ?? WordRereadResult())
    }
}

/// The page-level inputs of the candidate computation: original, lines, subject terms, spell checker and the
/// on-device model. Builds the keys and requests for single words.
@MainActor
struct WordCandidateContext {
    let digitizationID: UUID
    let background: DigitalPageInput.Background
    let lines: [RecognizedLine]
    let terms: Set<String>
    let checker: any SpellChecking
    let rerank: (@Sendable ([String], String, String) async -> [String])?
    /// Set when the model was needed and not available ("Ohne Geräte-Modell geordnet." in developer mode).
    let rerankStatus: RerankStatus

    /// Whether the on-device model answered or not, shared with the rerank closure (which runs elsewhere).
    nonisolated final class RerankStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var missing = false
        var modelMissing: Bool { lock.withLock { missing } }
        func markMissing() { lock.withLock { missing = true } }
    }

    /// nil if the page has no original to read from.
    static func make(
        source: Source, digitizationID: UUID, lines: [RecognizedLine], ai: AIService?,
        checker: any SpellChecking = AppSpellChecker.shared
    ) -> WordCandidateContext? {
        guard let request = try? DigitalPageRequest.make(
            source: source, digitizationID: digitizationID, lines: lines, highlights: [])
        else { return nil }
        let subject = source.batch?.subject
        let subjectName = subject?.name
        let status = RerankStatus()
        var rerank: (@Sendable ([String], String, String) async -> [String])?
        if let ai {
            rerank = { @Sendable candidates, before, after in
                if let ordered = await ai.rerankWords(
                    candidates: candidates, before: before, after: after, subject: subjectName) {
                    return ordered
                }
                status.markMissing()
                return candidates
            }
        }
        return WordCandidateContext(
            digitizationID: digitizationID, background: request.input.background, lines: lines,
            terms: Set(subject?.confirmedTerms ?? []), checker: checker, rerank: rerank, rerankStatus: status)
    }

    func key(lineID: UUID, wordIndex: Int) -> WordKey? {
        guard let line = lines.first(where: { $0.id == lineID }),
              let token = WordReview.tokens(of: line).first(where: { $0.index == wordIndex })
        else { return nil }
        return WordKey(digitizationID: digitizationID, lineID: lineID, wordIndex: wordIndex, text: token.text)
    }

    func job(lineID: UUID, wordIndex: Int) -> WordCandidatePrefetcher.Job? {
        guard let key = key(lineID: lineID, wordIndex: wordIndex),
              let line = lines.first(where: { $0.id == lineID }) else { return nil }
        let request = WordRereadRequest(
            background: background, line: line, wordIndex: wordIndex, pageLines: lines, terms: terms,
            spellChecker: checker, rerank: rerank)
        return WordCandidatePrefetcher.Job(key: key, request: request)
    }

    /// One job per marked word of the page, in reading order.
    func jobs(for review: PageWordReview) -> [WordCandidatePrefetcher.Job] {
        lines.sorted { $0.order < $1.order }.flatMap { line in
            review.markedTokens(of: line.id).compactMap { job(lineID: line.id, wordIndex: $0.index) }
        }
    }
}

/// The provider the app uses. UI tests (`-uiTestInMemory`) replace it with a deterministic one.
enum AppWordCandidates {
    static var provider: any WordCandidateProviding = VisionWordCandidateProvider(sources: DigitalPageSources())
}

/// Candidate provider of the UI tests: the recognizer's line alternatives and spelling guesses, plus the mock
/// on-device model's suggestions as `.model` candidates. No Vision, no model call, so that the result is the same on
/// every simulator.
nonisolated struct UITestWordCandidateProvider: WordCandidateProviding {
    func candidates(for request: WordRereadRequest) async throws -> [WordCandidate] {
        let local = WordReview.localSuggestions(
            line: request.line, wordIndex: request.wordIndex, checker: request.spellChecker, terms: request.terms)
        guard let token = WordReview.tokens(of: request.line).first(where: { $0.index == request.wordIndex }) else {
            return []
        }
        let word = token.core
        // Only readings that look like the written word (same first letter, similar length), like a real model's.
        let model = WordSuggestions.parse(AIBackend.mockWordSuggestionAnswer, original: word)
            .filter { suggestion in
                suggestion.first?.lowercased() == word.first?.lowercased() && abs(suggestion.count - word.count) <= 3
                    && !local.contains { $0.lowercased() == suggestion.lowercased() }
            }
        let merged = local.map { ($0, Set<WordCandidateSource>([.lineAlternative])) } + model.map { ($0, [.model]) }
        return merged.enumerated().map { index, item in
            WordCandidate(text: item.0, score: 1 - Double(index) * 0.1, sources: item.1)
        }
    }
}
