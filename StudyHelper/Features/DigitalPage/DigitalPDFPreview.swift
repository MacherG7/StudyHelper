import Observation
import QuickLook
import StudyData
import SwiftUI

/// Builds a digital PDF (off the main actor, cached) and shows it in QuickLook (search, select, copy, share).
@MainActor
@Observable
final class DigitalPDFPreview {
    /// Set when the PDF is ready; QuickLook is shown while it is non-nil.
    var url: URL?
    private(set) var isBuilding = false
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - pages: reads the pages' data on the main actor (throws a German `LocalizedError`).
    ///   - base: name of the file without ending (import name or subject).
    ///   - suffix: e.g. "Version 2".
    func open(
        with store: DigitalPageStore?, base: String, suffix: String? = nil,
        pages: () throws -> [DigitalPageRequest]
    ) {
        guard !isBuilding else { return }
        guard let store else {
            errorMessage = DigitalPageStoreError.unavailable.localizedDescription
            return
        }
        let requests: [DigitalPageRequest]
        do {
            requests = try pages()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let fileName = DigitalPageStore.pdfFileName(base: base, suffix: suffix)
        let title = DigitalPageStore.sanitized(base)
        isBuilding = true
        task = Task {
            defer { isBuilding = false }
            do {
                url = try await store.pdfFile(for: requests, title: title, fileName: fileName)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }
}

extension DigitalPageStore {
    /// File name base of an import: the original file name, else the subject's name.
    @MainActor
    static func baseName(of batch: ImportBatch) -> String {
        let name = batch.originalFileName.map(sanitized) ?? ""
        if !name.isEmpty { return name }
        return batch.subject?.name ?? "Seite"
    }
}
