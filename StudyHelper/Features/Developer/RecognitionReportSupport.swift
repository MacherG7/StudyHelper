import Foundation
import StudyCore
import StudyData
import UIKit

// Pure helpers behind the developer-mode error reports: what the user typed becomes an entry, imports and
// corrections become report parts, page areas become small JPEGs. No UI here, so all of it is unit tested.

/// What the report form collects.
struct ReportDraft: Equatable {
    var kind: RecognitionReportKind
    /// "Richtig wäre"; ignored for `order`.
    var expected: String
    var note: String
    /// For `order`: the line the reported line belongs after.
    var afterLineID: UUID?
    /// For `split`: further lines of the page that belong to the reported place.
    var extraLineIDs: Set<UUID> = []
    var includeImage = true

    /// Default for a form opened with a selected line (`misread`, expected text prefilled) or for a drawn area
    /// without a line (`missing`).
    static func initial(for line: RecognizedLine?) -> ReportDraft {
        ReportDraft(kind: line == nil ? .missing : .misread, expected: line?.text ?? "", note: "")
    }

    /// Builds the entry. Lines of kind `split` are the selected line plus `extraLineIDs`; `expected` is dropped
    /// when empty, for `order`, and when it equals the recognized text (nothing to report as "richtig").
    func makeEntry(
        importID: UUID, page: Int, pageSize: PageSize, lines: [RecognizedLine], selectedLineID: UUID?,
        drawnRect: NormalizedRect?, method: RecognitionMethod?, engine: String?, imageJPEG: Data?
    ) -> RecognitionReportEntry {
        let selected = lines.filter { line in
            line.id == selectedLineID || (kind == .split && extraLineIDs.contains(line.id))
        }
        let afterLine = kind == .order ? lines.first { $0.id == afterLineID } : nil
        let recognized = selected.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n")
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepExpected = kind != .order && !trimmedExpected.isEmpty
            && (kind == .missing || trimmedExpected != recognized.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecognitionReportEntry.make(
            importID: importID, page: page, pageSize: pageSize, selectedLines: selected, allLines: lines,
            kind: kind, expected: keepExpected ? trimmedExpected : nil,
            note: trimmedNote.isEmpty ? nil : trimmedNote, after: afterLine, drawnRect: drawnRect,
            method: method, engine: engine, imageJPEG: imageJPEG)
    }
}

// MARK: - Imports and pages

extension RecognitionReportImport {
    init(batch: ImportBatch) {
        let kind: String
        switch batch.kind {
        case .pdf, .goodnotes: kind = "pdf"
        case .photo, .scan: kind = "image"
        }
        self.init(
            id: batch.id, fileName: batch.originalFileName ?? batch.kind.germanName, kind: kind,
            variant: batch.goodnotesVariant, pageCount: batch.sources.count)
    }
}

/// Corrections the user made in the review, as report entries of all imports (read at export time).
enum RecognitionReportCorrections {
    /// UserDefaults key of the switch "Korrekturen mitschicken" (default: off).
    static let includeKey = "developer.reports.includeCorrections"

    /// The imports preselected for sending corrections: those among `candidates` that have reported errors.
    static func defaultSelection(candidates: Set<UUID>, reportedImports: Set<UUID>) -> Set<UUID> {
        candidates.intersection(reportedImports)
    }

    static func collect(from batches: [ImportBatch], date: Date = Date()) -> (
        imports: [RecognitionReportImport], entries: [RecognitionReportEntry]
    ) {
        var imports: [RecognitionReportImport] = []
        var entries: [RecognitionReportEntry] = []
        for batch in batches.sorted(by: { $0.createdAt < $1.createdAt }) {
            var batchEntries: [RecognitionReportEntry] = []
            for source in batch.sortedSources {
                guard let digitization = source.currentDigitization, !digitization.hasUnreadableData else { continue }
                let metadata = digitization.metadata
                batchEntries += RecognitionReportEntry.corrections(
                    from: digitization.lines, importID: batch.id, page: source.pageIndex + 1,
                    pageSize: source.pageSize, method: metadata.method,
                    engine: metadata.engineVersion ?? metadata.modelName, createdAt: date)
            }
            guard !batchEntries.isEmpty else { continue }
            imports.append(RecognitionReportImport(batch: batch))
            entries += batchEntries
        }
        return (imports, entries)
    }
}

// MARK: - Image crop

/// A small JPEG of a page area for a report entry.
nonisolated enum ReportImageCropper {
    /// Longest side of the result in pixels.
    static let maxSide: CGFloat = 600
    static let quality: CGFloat = 0.7
    /// Margin around the area as a fraction of the page.
    static let margin = 0.02

    /// Crops `rect` plus margin out of the page image and scales it down to `maxSide`; nil when the image cannot
    /// be read or the area is empty.
    @concurrent
    nonisolated static func jpeg(from data: Data, rect: NormalizedRect) async -> Data? {
        jpegSync(from: data, rect: rect)
    }

    nonisolated static func jpegSync(from data: Data, rect: NormalizedRect) -> Data? {
        guard !rect.isEmpty, let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let area = CGRect(
            x: (rect.x - margin) * width, y: (rect.y - margin) * height,
            width: (rect.width + 2 * margin) * width, height: (rect.height + 2 * margin) * height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard area.width >= 1, area.height >= 1, let cropped = cgImage.cropping(to: area) else { return nil }
        let scale = min(1, maxSide / max(area.width, area.height))
        let size = CGSize(width: max(1, (area.width * scale).rounded()), height: max(1, (area.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: quality) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - UI test data

extension RecognitionReportStore {
    /// One demo entry (`-uiTestSeedReports`).
    func seedDemoEntry() {
        let importID = UUID()
        let entry = RecognitionReportEntry(
            importID: importID, page: 1, pageSize: PageSize(width: 600, height: 800),
            rect: NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05), kind: .misread,
            recognized: "Chlorophyl ist der grune Blattfarbstoff", expected: "Chlorophyll ist der grüne Blattfarbstoff",
            note: "Umlaut fehlt", lines: [], method: RecognitionMethod.vision.rawValue, engine: "Mock")
        add(entry, importInfo: RecognitionReportImport(
            id: importID, fileName: "Fotosynthese.jpg", kind: "image", goodnotesVariant: nil, pageCount: 1))
    }
}
