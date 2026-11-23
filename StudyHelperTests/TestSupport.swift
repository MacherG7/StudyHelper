import Foundation
import StudyCore
import StudyData
import StudyImport
import SwiftData
import Testing
@testable import StudyHelper

/// Waits (polling) until `condition` holds; false after the timeout. Keeps tests from hanging.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// A closed door that a mock pipeline waits at (ignoring cancellation, like a recognizer in the middle of a page).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock(); defer { lock.unlock() }
        isOpen = true
    }

    private var opened: Bool {
        lock.lock(); defer { lock.unlock() }
        return isOpen
    }

    /// Waits at most 10 seconds.
    func wait() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

func makePage(index: Int, text: String, imageData: Data? = Data([0xFF, 0xD8, 0x01])) -> PageDigitization {
    let line = RecognizedLine(text: text, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05), order: 0)
    let result = DigitizationResult(
        lines: [line], highlights: [],
        metadata: RecognitionMetadata(method: .vision, engineVersion: "Mock", osVersion: "Test", deviceModel: "Mock"),
        originalMarkdown: OriginalTextMarkdown.build(lines: [line], highlights: []),
        pageSize: PageSize(width: 600, height: 800))
    return PageDigitization(pageIndex: index, result: result, imageData: imageData)
}

/// Pipeline mock: no Vision, no PDF parsing. Records what the coordinator asks for.
final class MockPipeline: DigitizingPipeline, @unchecked Sendable {
    private let lock = NSLock()
    private var imageCallCount = 0
    private var pdfCallList: [Set<Int>?] = []
    private var processed: [Int] = []

    /// Result for the n-th (1-based) `digitizeImage` call.
    var onImage: @Sendable (Int) async throws -> PageDigitization = { n in makePage(index: 0, text: "Bild \(n)") }
    /// If set, `digitizePDFPages` throws it right away (a document-level error).
    var pdfError: (any Error)?
    var pdfPageCount = 3
    var failingPages: Set<Int> = []

    var imageCalls: Int { lock.withLock { imageCallCount } }
    /// `pageIndices` of every `digitizePDFPages` call.
    var pdfCalls: [Set<Int>?] { lock.withLock { pdfCallList } }
    /// Page indices in the order they were processed.
    var processedPages: [Int] { lock.withLock { processed } }

    @concurrent
    func digitizeImage(data: Data) async throws -> PageDigitization {
        let n = lock.withLock { imageCallCount += 1; return imageCallCount }
        return try await onImage(n)
    }

    @concurrent
    func digitizePDFPages(
        data: Data, reducedPDF: Data?, pageIndices: Set<Int>?,
        onPage: @concurrent (_ result: PageResult, _ pagesDone: Int, _ pageCount: Int) async throws -> Void
    ) async throws {
        lock.withLock { pdfCallList.append(pageIndices) }
        if let pdfError { throw pdfError }
        let wanted = (0..<pdfPageCount).filter { pageIndices?.contains($0) ?? true }
        for (position, index) in wanted.enumerated() {
            try Task.checkCancellation()
            lock.withLock { processed.append(index) }
            let result: PageResult = failingPages.contains(index)
                ? .failure(PageFailure(pageIndex: index, message: "Seite \(index + 1) konnte nicht erkannt werden."))
                : .success(makePage(index: index, text: "Seite \(index + 1)"))
            try await onPage(result, position + 1, wanted.count)
        }
    }
}

/// In-memory store with a coordinator that uses `pipeline`.
@MainActor
struct CoordinatorFixture {
    let container: ModelContainer
    let repository: StudyRepository
    let subject: Subject
    let pipeline: MockPipeline
    let coordinator: ImportCoordinator

    init(pipeline: MockPipeline = MockPipeline()) throws {
        container = try ModelContainerFactory.makeContainer(inMemory: true)
        repository = StudyRepository(container: container)
        subject = try repository.createSubject(name: "Biologie")
        self.pipeline = pipeline
        let defaults = UserDefaults(suiteName: "StudyHelperTests-\(UUID().uuidString)") ?? .standard
        coordinator = ImportCoordinator(
            repository: repository, settings: StudySettings(defaults: defaults), pipelineFactory: { _ in pipeline })
    }

    var batch: ImportBatch? { subject.imports.first }

    /// A PDF stand-in: the mock pipeline never reads the bytes.
    static func fakePDF(pages: Int = 3, name: String = "Notiz.pdf") -> PickedPDF {
        PickedPDF(
            name: name, data: Data("%PDF-fake".utf8), pageCount: pages,
            pageSizes: Array(repeating: PageSize(width: 595, height: 842), count: pages),
            variant: .other, document: nil)
    }
}
