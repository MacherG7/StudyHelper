import Foundation
import StudyCore

/// The digitization of one page or image, plus the rendered page for storage and display.
public struct PageDigitization: Sendable {
    /// 0-based page index (0 for single images).
    public var pageIndex: Int
    public var result: DigitizationResult
    /// JPEG of the page as the user sees it (PDF pages with annotations and rotation, about 2× scale; photos
    /// rotated upright). nil only if the image could not be encoded.
    public var imageData: Data?

    public init(pageIndex: Int, result: DigitizationResult, imageData: Data?) {
        self.pageIndex = pageIndex
        self.result = result
        self.imageData = imageData
    }
}

/// A page of a PDF that could not be digitized. The other pages of the document are not affected.
public struct PageFailure: Error, Hashable, Sendable {
    /// 0-based page index.
    public var pageIndex: Int
    /// What went wrong, in German, for the user.
    public var message: String

    public init(pageIndex: Int, message: String) {
        self.pageIndex = pageIndex
        self.message = message
    }
}

/// Result for one PDF page: the digitization or the reason it failed.
public typealias PageResult = Result<PageDigitization, PageFailure>

extension Array where Element == PageResult {
    /// The pages that were digitized, in page order.
    public var pages: [PageDigitization] {
        compactMap { if case .success(let page) = $0 { page } else { nil } }
    }

    /// The pages that failed, in page order.
    public var failures: [PageFailure] {
        compactMap { if case .failure(let failure) = $0 { failure } else { nil } }
    }
}

public enum DigitizationError: Error, Hashable, Sendable {
    /// The data is not a readable PDF.
    case notAPDF
    /// Password-protected PDFs cannot be read.
    case encrypted
    /// The PDF has no pages.
    case emptyDocument
    /// A page could not be rendered to an image.
    case renderingFailed(pageIndex: Int)
    /// The data is not a readable image.
    case unreadableImage
}

extension DigitizationError: LocalizedError {
    /// German, for the user.
    public var errorDescription: String? {
        switch self {
        case .notAPDF: "Die Datei ist kein lesbares PDF."
        case .encrypted: "Das PDF ist passwortgeschützt und kann nicht gelesen werden."
        case .emptyDocument: "Das PDF enthält keine Seiten."
        case .renderingFailed(let index): "Seite \(index + 1) konnte nicht als Bild dargestellt werden."
        case .unreadableImage: "Das Bild konnte nicht gelesen werden."
        }
    }
}
