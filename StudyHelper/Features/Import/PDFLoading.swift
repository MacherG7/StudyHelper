import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import StudyCore
import StudyImport

/// A PDF the user picked, read and inspected off the main actor (see `PDFLoader`).
nonisolated struct PickedPDF: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let pageCount: Int
    let pageSizes: [PageSize]
    let variant: GoodnotesVariant
    /// Parsed Goodnotes structure (editable/reduced exports only); needed for the pairing check.
    let document: GoodnotesDocument?

    var variantName: String {
        switch variant {
        case .editable: "Goodnotes-Export (bearbeitbar)"
        case .reduced: "Goodnotes-Export (reduziert)"
        case .other: "PDF"
        }
    }
}

nonisolated enum PDFLoadError: Error, LocalizedError {
    case goodnotesFile(String)
    case notAPDF(String)
    case encrypted(String)
    case empty(String)
    case unreadable(String, String)

    var errorDescription: String? {
        switch self {
        case .goodnotesFile(let name):
            "„\(name)“ ist eine .goodnotes-Datei. Dieses Format wird nicht unterstützt. Exportiere die Notiz in Goodnotes über „Teilen → Exportieren → PDF“ und importiere das PDF."
        case .notAPDF(let name): "Die Datei „\(name)“ ist kein lesbares PDF."
        case .encrypted(let name): "Das PDF „\(name)“ ist passwortgeschützt und kann nicht gelesen werden."
        case .empty(let name): "Das PDF „\(name)“ enthält keine Seiten."
        case .unreadable(let name, let detail): "Die Datei „\(name)“ konnte nicht gelesen werden: \(detail)"
        }
    }
}

nonisolated enum PDFLoader {
    /// True for `.goodnotes` files (checked before anything is read).
    static func isGoodnotesFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "goodnotes"
    }

    /// Reads and inspects a PDF. Runs on the global executor: reading and parsing a large export takes a while.
    @concurrent
    static func load(url: URL, displayName: String? = nil) async throws -> PickedPDF {
        let name = displayName ?? url.lastPathComponent
        if isGoodnotesFile(url) { throw PDFLoadError.goodnotesFile(name) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw PDFLoadError.unreadable(name, error.localizedDescription)
        }
        return try inspect(data: data, name: name)
    }

    static func inspect(data: Data, name: String) throws -> PickedPDF {
        guard let document = PDFDocument(data: data) else { throw PDFLoadError.notAPDF(name) }
        if document.isLocked, !document.unlock(withPassword: "") { throw PDFLoadError.encrypted(name) }
        guard document.pageCount > 0 else { throw PDFLoadError.empty(name) }
        var sizes: [PageSize] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                sizes.append(PageRenderer.pageSize(of: page))
            } else {
                sizes.append(PageSize(width: 595, height: 842))
            }
        }
        var variant = GoodnotesVariant.other
        var parsed: GoodnotesDocument?
        do {
            let goodnotes = try GoodnotesParser.parse(data: data)
            variant = goodnotes.variant
            parsed = goodnotes.variant == .other ? nil : goodnotes
        } catch GoodnotesError.goodnotesFileNotSupported {
            throw PDFLoadError.goodnotesFile(name)
        } catch GoodnotesError.notAPDF {
            throw PDFLoadError.notAPDF(name)
        } catch GoodnotesError.encrypted {
            throw PDFLoadError.encrypted(name)
        } catch {
            // Not recognizable as a Goodnotes export: a generic PDF.
        }
        return PickedPDF(
            name: name, data: data, pageCount: document.pageCount, pageSizes: sizes,
            variant: variant, document: parsed)
    }
}

/// Outcome of comparing two picked PDFs (SPEC §1: "ordnet beide Exporte derselben Notiz einander zu").
nonisolated struct PDFPairing: Sendable {
    enum State: Sendable {
        /// Only one file picked.
        case single
        /// Same page count and sizes; the user still has to confirm that they belong together.
        case compatible
        /// Cannot be paired; the text explains why. Only `main` is imported.
        case incompatible(String)
    }

    let main: PickedPDF
    let reduced: PickedPDF?
    let state: State

    init?(files: [PickedPDF]) {
        guard let first = files.first else { return nil }
        guard files.count >= 2 else {
            main = first; reduced = nil; state = .single
            return
        }
        let second = files[1]
        let editable = files.first { $0.variant == .editable }
        let reducedFile = files.first { $0.variant == .reduced }
        guard let editable, let reducedFile, let editableDoc = editable.document, let reducedDoc = reducedFile.document else {
            main = first; reduced = nil
            state = .incompatible(
                "Für den Abgleich braucht es ein bearbeitbares und ein reduziertes Goodnotes-PDF derselben Notiz. Importiert wird nur „\(first.name)“; „\(second.name)“ wird nicht verwendet.")
            return
        }
        main = editable
        switch GoodnotesPairing.check(editable: editableDoc, reduced: reducedDoc) {
        case .compatible:
            reduced = reducedFile; state = .compatible
        case .pageCountMismatch(let a, let b):
            reduced = nil
            state = .incompatible(
                "Die Seitenzahlen passen nicht zusammen (bearbeitbar: \(a), reduziert: \(b)). Die Exporte gehören vermutlich nicht zur selben Notiz. Importiert wird nur „\(editable.name)“, ohne Abgleich.")
        case .pageSizeMismatch(let index):
            reduced = nil
            state = .incompatible(
                "Die Seitengröße von Seite \(index + 1) passt nicht zusammen. Die Exporte gehören vermutlich nicht zur selben Notiz. Importiert wird nur „\(editable.name)“, ohne Abgleich.")
        case .wrongVariants:
            reduced = nil
            state = .incompatible(
                "Die beiden Dateien lassen sich nicht zuordnen. Importiert wird nur „\(editable.name)“, ohne Abgleich.")
        }
    }
}

nonisolated enum ImageProbe {
    /// Pixel size of an image file without decoding it (orientation applied); a 1×1 placeholder if unreadable.
    static func size(of data: Data) -> PageSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return PageSize(width: 1, height: 1) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? PageSize(width: height, height: width) : PageSize(width: width, height: height)
    }
}
