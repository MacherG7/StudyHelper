import Foundation
import Observation
import PhotosUI
import StudyCore
import StudyData
import StudyImport
import SwiftData
import SwiftUI

/// What the coordinator needs from the digitization pipeline. `DigitizationPipeline` is the production
/// implementation; tests inject a mock (no Vision, no real PDFs).
nonisolated protocol DigitizingPipeline: Sendable {
    @concurrent
    func digitizeImage(data: Data) async throws -> PageDigitization

    /// See `DigitizationPipeline.digitizePDFPages`: only `pageIndices` are processed (nil: all pages), and
    /// `pagesDone`/`pageCount` count only those.
    @concurrent
    func digitizePDFPages(
        data: Data, reducedPDF: Data?, pageIndices: Set<Int>?,
        onPage: @concurrent (_ result: PageResult, _ pagesDone: Int, _ pageCount: Int) async throws -> Void
    ) async throws
}

nonisolated extension DigitizationPipeline: DigitizingPipeline {}

/// Runs imports and (re-)recognitions without blocking the UI.
///
/// Threading: the coordinator and everything it touches in SwiftData lives on the main actor. The heavy work
/// (PDF parsing, rendering, Vision) happens inside the pipeline's async functions, which run on the global
/// executor; the coordinator only awaits them. After each page the pipeline hands the result back (`onPage`),
/// and the coordinator saves it on the main actor before the next page starts. One job runs at a time;
/// `cancel()` stops after the current page/layer, already saved pages stay.
///
/// The running job's subject and batch cannot be deleted (`deleteSubject`, `deleteBatch`), and the save paths
/// stop quietly if a model is gone anyway.
@MainActor
@Observable
final class ImportCoordinator {
    struct Progress: Equatable {
        var title: String
        var message: String
        /// 0…1, nil while unknown.
        var fraction: Double?
        var isCancelling = false
    }

    /// The running job, if any. Drives the progress strip in `RootView`.
    private(set) var progress: Progress?
    /// Batch the running job works on.
    private(set) var activeBatchID: UUID?
    /// Subject the running job belongs to.
    private(set) var activeSubjectID: UUID?
    /// Short summary of the last finished job ("3 von 3 Seiten erkannt"); shown until dismissed.
    var notice: String?
    /// German error message for an alert.
    var errorMessage: String?

    var isRunning: Bool { progress != nil }

    @ObservationIgnored private let repository: StudyRepository
    @ObservationIgnored private let settings: StudySettings
    @ObservationIgnored private let pipelineFactory: @MainActor (PipelineSettings) -> any DigitizingPipeline
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pdfRun: PDFRun?
    @ObservationIgnored private var announcedQuarter = 0

    /// - Parameter pipelineFactory: builds the pipeline for a job; tests return a mock.
    init(
        repository: StudyRepository, settings: StudySettings = StudySettings(),
        pipelineFactory: @escaping @MainActor (PipelineSettings) -> any DigitizingPipeline = { DigitizationPipeline(settings: $0) }
    ) {
        self.repository = repository
        self.settings = settings
        self.pipelineFactory = pipelineFactory
    }

    // MARK: Entry points

    /// Photos chosen in the photo library (order kept). The data is loaded first, then imported as one batch.
    func importPhotoItems(_ items: [PhotosPickerItem], into subject: Subject) {
        guard !items.isEmpty else { return }
        startImageImport(title: "Fotos importieren", message: "Fotos werden geladen…", kind: .photo, subject: subject) { [self] in
            var datas: [Data] = []
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                update(message: items.count == 1 ? "Foto wird geladen…" : "Foto \(index + 1) von \(items.count) wird geladen…")
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImportFailure.unreadableImage
                }
                datas.append(data)
            }
            return datas
        }
    }

    /// Camera photo or scanner pages (already in memory). The JPEG encoding runs off the main actor, one page at a time.
    func importImages(_ images: [UIImage], kind: ImportKind, into subject: Subject) {
        guard !images.isEmpty else { return }
        startImageImport(
            title: kind == .scan ? "Scan importieren" : "Foto importieren", message: "Bilder werden vorbereitet…",
            kind: kind, subject: subject
        ) { [self] in
            var datas: [Data] = []
            for (index, image) in images.enumerated() {
                try Task.checkCancellation()
                if images.count > 1 { update(message: "Bild \(index + 1) von \(images.count) wird vorbereitet…") }
                guard let data = await Self.jpegData(of: image) else { throw ImportFailure.unreadableImage }
                datas.append(data)
            }
            return datas
        }
    }

    /// Images that are already encoded (also the entry point for tests).
    func importImageData(_ datas: [Data], kind: ImportKind, into subject: Subject) {
        guard !datas.isEmpty else { return }
        startImageImport(title: "Bilder importieren", message: "Bilder werden vorbereitet…", kind: kind, subject: subject) { datas }
    }

    /// A PDF, optionally with the matching reduced Goodnotes export for cross-checking.
    func importPDF(main: PickedPDF, reduced: PickedPDF?, into subject: Subject) {
        guard begin(title: "PDF importieren", message: "Import wird vorbereitet…", subjectID: subject.id) else { return }
        run { [self] in
            let inputs = main.pageSizes.map { SourceInput(imageData: nil, pageSize: $0) }
            let batch = try repository.createBatch(
                in: subject, kind: main.variant == .other ? .pdf : .goodnotes, originalFileName: main.name,
                originalPDF: main.data, goodnotesVariant: main.variant, reducedPDF: reduced?.data, pages: inputs)
            activeBatchID = batch.id
            try await runPDF(batch: batch, targets: Set(0..<inputs.count))
        }
    }

    /// Recognizes pages that still wait for it (cancelled or interrupted import, or an unfinished re-recognition).
    func recognizePending(in batch: ImportBatch) {
        do {
            let pending = try repository.sourcesNeedingDigitization(in: batch)
            start(recognizing: pending, in: batch, prepare: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Explicit user action "Neu erkennen": old versions and manual corrections are kept by the repository.
    func reRecognize(_ sources: [Source], in batch: ImportBatch) {
        start(recognizing: sources, in: batch, prepare: true)
    }

    /// Retries pages whose recognition failed.
    func retryFailed(in batch: ImportBatch) {
        let failed = batch.sortedSources.filter { $0.digitizationState == .failed }
        start(recognizing: failed, in: batch, prepare: true)
    }

    func cancel() {
        guard progress != nil, progress?.isCancelling == false else { return }
        progress?.isCancelling = true
        progress?.message = "Wird abgebrochen…"
        task?.cancel()
    }

    /// Waits until the running job (if any) has ended.
    func waitUntilIdle() async {
        await task?.value
    }

    // MARK: Deleting

    /// True while the running job belongs to `subject`.
    func isBusy(with subject: Subject) -> Bool {
        progress != nil && activeSubjectID == subject.id
    }

    /// Deletes a subject unless the running job works on it.
    func deleteSubject(_ subject: Subject) throws {
        if isBusy(with: subject) { throw ImportFailure.subjectBusy }
        try repository.deleteSubject(subject)
    }

    /// Deletes an import unless it is the one being recognized.
    func deleteBatch(_ batch: ImportBatch) throws {
        if progress != nil, activeBatchID == batch.id { throw ImportFailure.batchBusy }
        try repository.deleteBatch(batch)
    }

    // MARK: Job handling

    private func begin(title: String, message: String, subjectID: UUID?) -> Bool {
        guard progress == nil else {
            errorMessage = "Es läuft bereits ein Import. Warte, bis er fertig ist, oder brich ihn ab."
            return false
        }
        notice = nil
        announcedQuarter = 0
        activeSubjectID = subjectID
        progress = Progress(title: title, message: message, fraction: nil)
        announce(title)
        return true
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        task = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                self?.noteCancelled()
            } catch ImportFailure.targetDeleted {
                self?.notice = "Der Import wurde gelöscht, die Erkennung wurde beendet."
            } catch {
                self?.fail(error.localizedDescription)
            }
            self?.endJob()
        }
    }

    private func endJob() {
        let finished = notice
        progress = nil
        activeBatchID = nil
        activeSubjectID = nil
        pdfRun = nil
        task = nil
        if let finished { announce(finished) }
    }

    private func fail(_ message: String) {
        errorMessage = message
        announce(message)
    }

    /// Changes the running job's text and fraction without losing `isCancelling` (a cancelled job keeps saying so).
    private func update(title: String? = nil, message: String, fraction: Double? = nil) {
        guard var current = progress else { return }
        if let title { current.title = title }
        if !current.isCancelling { current.message = message }
        current.fraction = fraction
        progress = current
        if let fraction, !current.isCancelling {
            let quarter = Int(fraction * 4)
            if quarter > announcedQuarter, quarter < 4 {
                announcedQuarter = quarter
                announce("\(quarter * 25) Prozent erkannt")
            }
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    private func noteCancelled() {
        var text = "Abgebrochen. Bereits erkannte Seiten bleiben erhalten."
        if let id = activeBatchID,
           let batch = (try? repository.context.fetch(FetchDescriptor<ImportBatch>(predicate: #Predicate { $0.id == id })))?.first,
           !batch.isDeleted {
            let waiting = (try? repository.sourcesNeedingDigitization(in: batch))?.count ?? 0
            if waiting > 0 {
                text += waiting == 1 ? " 1 Seite wartet noch auf die Erkennung." : " \(waiting) Seiten warten noch auf die Erkennung."
            }
        }
        notice = text
    }

    private func start(recognizing sources: [Source], in batch: ImportBatch, prepare: Bool) {
        guard !sources.isEmpty else { return }
        guard begin(title: "Seiten erkennen", message: "Erkennung wird vorbereitet…", subjectID: batch.subject?.id) else { return }
        run { [self] in
            try ensureAlive(batch)
            if prepare { try repository.prepareReRecognition(for: sources) }
            activeBatchID = batch.id
            if batch.kind.isPDF {
                try await runPDF(batch: batch, targets: Set(sources.map(\.pageIndex)))
            } else {
                try await runImages(sources, in: batch)
            }
        }
    }

    private func makePipeline(for subject: Subject?) -> any DigitizingPipeline {
        pipelineFactory(PipelineSettings(
            multiPass: settings.multiPassRecognition, customWords: subject?.confirmedTerms ?? []))
    }

    /// Throws `targetDeleted` if a model of the job has been deleted in the meantime.
    private func ensureAlive(_ models: any PersistentModel...) throws {
        for model in models where model.isDeleted || model.modelContext == nil {
            throw ImportFailure.targetDeleted
        }
    }

    // MARK: Images

    private func startImageImport(
        title: String, message: String, kind: ImportKind, subject: Subject,
        load: @escaping @MainActor () async throws -> [Data]
    ) {
        guard begin(title: title, message: message, subjectID: subject.id) else { return }
        run { [self] in
            let datas = try await load()
            try Task.checkCancellation()
            try ensureAlive(subject)
            let inputs = datas.map { SourceInput(imageData: $0, pageSize: ImageProbe.size(of: $0)) }
            let batch = try repository.createBatch(in: subject, kind: kind, pages: inputs)
            activeBatchID = batch.id
            try await runImages(batch.sortedSources, in: batch)
        }
    }

    @concurrent
    private nonisolated static func jpegData(of image: UIImage) async -> Data? {
        image.jpegData(compressionQuality: 0.9)
    }

    private func runImages(_ sources: [Source], in batch: ImportBatch) async throws {
        try ensureAlive(batch)
        let pipeline = makePipeline(for: batch.subject)
        let total = sources.count
        var saved = 0
        var failed = 0
        var skipped = 0
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            try ensureAlive(batch, source)
            update(
                title: "Seiten erkennen",
                message: total == 1 ? "Bild wird erkannt…" : "Bild \(index + 1) von \(total) wird erkannt…",
                fraction: Double(index) / Double(total))
            guard let data = source.imageData else {
                try repository.markDigitizationFailed(source, message: "Das gespeicherte Bild fehlt.")
                failed += 1
                continue
            }
            let page: PageDigitization
            do {
                page = try await pipeline.digitizeImage(data: data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ensureAlive(source)
                try repository.markDigitizationFailed(source, message: error.localizedDescription)
                failed += 1
                continue
            }
            try ensureAlive(batch, source)
            // The first recognition stores the upright, scaled JPEG; later ones must not re-encode that copy again.
            if source.currentDigitization == nil, let image = page.imageData { source.imageData = image }
            let outcome = try repository.saveDigitization(page.result, for: source)
            skipped += outcome.skippedCorrectionCount
            saved += 1
        }
        notice = summary(saved: saved, failed: failed, skipped: skipped, unit: total == 1 ? "Bild" : "Bilder", total: total)
    }

    // MARK: PDF

    /// State of the running PDF job; read by `savePage`, which the pipeline calls after each page.
    private final class PDFRun {
        let batch: ImportBatch
        let targets: Set<Int>
        var saved = 0
        var failed = 0
        var skipped = 0

        init(batch: ImportBatch, targets: Set<Int>) {
            self.batch = batch
            self.targets = targets
        }
    }

    private func runPDF(batch: ImportBatch, targets: Set<Int>) async throws {
        try ensureAlive(batch)
        guard let pdf = batch.originalPDF else { throw ImportFailure.originalPDFMissing }
        guard !targets.isEmpty else { return }
        let pipeline = makePipeline(for: batch.subject)
        let run = PDFRun(batch: batch, targets: targets)
        pdfRun = run
        update(
            title: "Seiten erkennen",
            message: targets.count == 1 ? "Seite wird erkannt…" : "Seite 1 von \(targets.count) wird erkannt…", fraction: 0)
        do {
            // Only the wanted pages are processed (a single-page re-recognition does not touch earlier pages).
            try await pipeline.digitizePDFPages(data: pdf, reducedPDF: batch.reducedPDF, pageIndices: targets) { @Sendable [weak self] result, done, total in
                guard let self else { throw CancellationError() }
                try await self.savePage(result, done: done, total: total)
            }
        } catch let error as DigitizationError {
            // The document as a whole could not be processed: every wanted page failed.
            try ensureAlive(batch)
            let message = error.errorDescription ?? "Das PDF konnte nicht verarbeitet werden."
            for source in batch.sortedSources where targets.contains(source.pageIndex) && source.digitizationState != .done {
                try repository.markDigitizationFailed(source, message: message)
            }
            fail(message)
            return
        }
        notice = summary(
            saved: run.saved, failed: run.failed, skipped: run.skipped,
            unit: run.saved + run.failed == 1 ? "Seite" : "Seiten", total: targets.count)
    }

    private func savePage(_ result: PageResult, done: Int, total: Int) async throws {
        guard let run = pdfRun else { throw CancellationError() }
        try ensureAlive(run.batch)
        let index: Int
        switch result {
        case .success(let page): index = page.pageIndex
        case .failure(let failure): index = failure.pageIndex
        }
        if run.targets.contains(index), let source = run.batch.sources.first(where: { $0.pageIndex == index }) {
            try ensureAlive(source)
            switch result {
            case .success(let page):
                if let image = page.imageData { source.imageData = image }
                let outcome = try repository.saveDigitization(page.result, for: source)
                run.skipped += outcome.skippedCorrectionCount
                run.saved += 1
            case .failure(let failure):
                try repository.markDigitizationFailed(source, message: failure.message)
                run.failed += 1
            }
        }
        if done < total {
            update(message: "Seite \(done + 1) von \(total) wird erkannt…", fraction: Double(done) / Double(max(total, 1)))
        }
    }

    // MARK: Helpers

    private func summary(saved: Int, failed: Int, skipped: Int, unit: String, total: Int) -> String {
        var text = "\(saved) von \(total) \(unit) erkannt."
        if failed > 0 { text += " \(failed) fehlgeschlagen: Öffne den Import, um es erneut zu versuchen." }
        if skipped > 0 {
            text += skipped == 1
                ? " 1 gespeicherte Korrektur konnte nicht gelesen werden und wurde nicht angewendet."
                : " \(skipped) gespeicherte Korrekturen konnten nicht gelesen werden und wurden nicht angewendet."
        }
        return text
    }
}

enum ImportFailure: Error, LocalizedError {
    case unreadableImage
    case originalPDFMissing
    case subjectBusy
    case batchBusy
    /// A model of the running job was deleted; the job ends quietly.
    case targetDeleted

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Das Bild konnte nicht gelesen werden."
        case .originalPDFMissing: "Das Original-PDF dieses Imports ist nicht mehr gespeichert. Importiere es erneut."
        case .subjectBusy: "In diesem Fach läuft gerade ein Import. Warte, bis er fertig ist, oder brich ihn ab."
        case .batchBusy: "Dieser Import wird gerade erkannt. Brich die Erkennung zuerst ab."
        case .targetDeleted: "Der Import wurde gelöscht."
        }
    }
}
