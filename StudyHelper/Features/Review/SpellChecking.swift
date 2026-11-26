import Foundation
import StudyCore
import UIKit

/// German spell checking with the system's `UITextChecker`. Cheap and cached per word: the checker is asked once
/// for every word, later lookups come from the cache. `UITextChecker` belongs to the main actor, so every real
/// lookup runs there (directly when called from the main thread, otherwise the caller waits for it); the caches are
/// guarded by a lock that is never held while waiting for the main thread.
nonisolated final class UITextCheckerSpellChecking: SpellChecking, @unchecked Sendable {
    private let language: String
    private let lock = NSLock()
    private var knownCache: [String: Bool] = [:]
    private var guessCache: [String: [String]] = [:]
    /// Created on first use, only touched on the main thread.
    nonisolated(unsafe) private var checker: UITextChecker?

    init(language: String = "de_DE") {
        self.language = language
    }

    private func onMain<T: Sendable>(_ work: @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(work) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    func isKnown(_ word: String) -> Bool {
        guard !word.isEmpty else { return true }
        if let cached = lock.withLock({ knownCache[word] }) { return cached }
        let language = language
        let known = onMain {
            let checker = self.checker ?? UITextChecker()
            self.checker = checker
            let range = NSRange(location: 0, length: (word as NSString).length)
            return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
                .location == NSNotFound
        }
        lock.withLock { knownCache[word] = known }
        return known
    }

    func guesses(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        if let cached = lock.withLock({ guessCache[word] }) { return cached }
        let language = language
        let guesses = onMain {
            let checker = self.checker ?? UITextChecker()
            self.checker = checker
            let range = NSRange(location: 0, length: (word as NSString).length)
            return checker.guesses(forWordRange: range, in: word, language: language) ?? []
        }
        lock.withLock { guessCache[word] = guesses }
        return guesses
    }
}

/// The spell checker the review uses. UI tests (`-uiTestInMemory`) replace it with a fixed word list, because the
/// simulator's dictionaries are not the same on every system version.
enum AppSpellChecker {
    static var shared: any SpellChecking = UITextCheckerSpellChecking()
}

/// Spell checker of the UI tests: knows every word except the listed ones, never guesses.
nonisolated struct UITestSpellChecker: SpellChecking, SpellCheckerIdentifying {
    let unknown: Set<String>

    var cacheIdentity: AnyHashable { unknown }

    func isKnown(_ word: String) -> Bool { !unknown.contains(word.lowercased()) }
    func guesses(for word: String) -> [String] { [] }
}
