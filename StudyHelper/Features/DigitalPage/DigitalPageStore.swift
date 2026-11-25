import CryptoKit
import Foundation
import ImageIO
import StudyCore
import StudyData
import StudyImport
import SwiftUI
import UniformTypeIdentifiers

/// Everything the store needs to build one page: Sendable copies of the model data (read on the main actor).
nonisolated struct DigitalPageRequest: Sendable {
    /// The digitization the page shows (the source's id for a page without one).
    let digitizationID: UUID
    let input: DigitalPageInput
}

enum DigitalPageStoreError: Error, LocalizedError {
    case noText
    case noOriginal
    case nothingToShow
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noText: "Diese Seite hat keinen lesbaren Text."
        case .noOriginal: "Das Original dieser Seite ist nicht gespeichert."
        case .nothingToShow: "Dieser Import hat keine Seiten."
        case .unavailable: "Die digitale Seite ist gerade nicht verfügbar."
        }
    }
}

extension DigitalPageRequest {
    /// The page of `source` with the lines and highlights of `digitization` (default: the current one).
    /// Throws `.noText` if the page has no readable digitization and `.noOriginal` if its original is gone.
    @MainActor
    static func make(
        source: Source, digitization: Digitization? = nil, originalPDF: Data? = nil
    ) throws -> DigitalPageRequest {
        guard let digitization = digitization ?? source.currentDigitization else { throw DigitalPageStoreError.noText }
        guard !digitization.hasUnreadableData else { throw DigitalPageStoreError.noText }
        return try make(
            source: source, digitizationID: digitization.id, lines: digitization.lines.sorted { $0.order < $1.order },
            highlights: digitization.highlights, originalPDF: originalPDF)
    }

    @MainActor
    static func make(
        source: Source, digitizationID: UUID, lines: [RecognizedLine], highlights: [RecognizedHighlight],
        originalPDF: Data? = nil
    ) throws -> DigitalPageRequest {
        let background: DigitalPageInput.Background
        if let batch = source.batch, let pdf = originalPDF ?? batch.originalPDF {
            background = .pdf(data: pdf, pageIndex: source.pageIndex, variant: batch.goodnotesVariant)
        } else if let image = source.imageData {
            background = .image(data: image)
        } else {
            throw DigitalPageStoreError.noOriginal
        }
        return DigitalPageRequest(
            digitizationID: digitizationID,
            input: DigitalPageInput(background: background, lines: lines, highlights: highlights))
    }

    /// All pages of an import in page order, each with its current digitization. Pages that are not recognized (yet)
    /// or cannot be read are included without text, so that the page count matches the original.
    @MainActor
    static func all(of batch: ImportBatch) throws -> [DigitalPageRequest] {
        let pdf = batch.originalPDF
        let requests = try batch.sortedSources.map { source -> DigitalPageRequest in
            do {
                return try make(source: source, originalPDF: pdf)
            } catch DigitalPageStoreError.noText {
                return try make(source: source, digitizationID: source.id, lines: [], highlights: [], originalPDF: pdf)
            }
        }
        guard !requests.isEmpty else { throw DigitalPageStoreError.nothingToShow }
        return requests
    }
}

/// Lets one piece of work run at a time; waiting callers are served latest first ("latest request wins": when the
/// user pages quickly, the page on screen is built before the ones that were skipped), and a cancelled waiter leaves
/// the queue at once. The work itself runs outside the actor, so the gate never blocks while something is built.
actor BuildGate {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Runs `work` as soon as the slot is free. Throws `CancellationError` without running it if the caller was
    /// cancelled while waiting; `work` checks cancellation again itself once it runs.
    @concurrent
    nonisolated func run<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try work()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if let next = waiters.popLast() {
            next.continuation.resume()
        } else {
            busy = false
        }
    }
}

/// Builds the "digitale Seite" off the main actor and keeps the results in `Caches/DigitalPages/`.
///
/// Cache key (see `imageKey`/`pdfKey`): digitization id + mode + hash of the encoded lines and highlights (and of the
/// original's identity) + `DigitalPageBuilder.version` + scale. A correction, a re-recognition or a restored version
/// changes the content hash, so stale files are never shown. Writing an image deletes the older files of the same
/// digitization and mode, so the cache does not grow with every correction; everything else ages out (`prune`).
///
/// Builds are heavy synchronous work: at most one image build and one PDF build run at a time (`BuildGate`, latest
/// request first), so quick paging never occupies several threads with stale pages.
nonisolated final class DigitalPageStore: Sendable {
    let directory: URL
    /// Opened originals shared by the image builds (the package keeps only the last few open).
    private let sources = DigitalPageSources()
    private let imageGate = BuildGate()
    private let pdfGate = BuildGate()

    /// Files not used for this long are deleted.
    static let maxAge: TimeInterval = 30 * 24 * 3600
    /// The cache is trimmed (oldest first) to this size.
    static let maxBytes = 300 * 1024 * 1024

    /// - Parameters:
    ///   - directory: cache folder; nil uses `Caches/DigitalPages` (tests pass a temporary folder).
    ///   - pruneAtStart: clean the folder in the background.
    init(directory: URL? = nil, pruneAtStart: Bool = true) {
        let folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigitalPages", isDirectory: true)
        self.directory = folder
        if pruneAtStart {
            Task.detached(priority: .utility) { Self.prune(folder) }
        }
    }

    // MARK: Keys

    /// Pixels per point for the display image: PDF pages 2× (sharp when zoomed), photos as they are.
    static func displayScale(for input: DigitalPageInput) -> Double {
        switch input.background {
        case .pdf: 2
        case .image: 1
        }
    }

    /// Stable hash of everything of a page that changes its look: encoded lines and highlights, the original's identity.
    static func contentHash(of input: DigitalPageInput) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: (try? encoder.encode(input.lines)) ?? Data())
        hasher.update(data: Data("|".utf8))
        hasher.update(data: (try? encoder.encode(input.highlights)) ?? Data())
        hasher.update(data: Data("|".utf8))
        switch input.background {
        case .pdf(let data, let pageIndex, let variant):
            hasher.update(data: Data("pdf-\(data.count)-\(pageIndex)-\(variant?.rawValue ?? "?")".utf8))
        case .image(let data):
            hasher.update(data: Data("image-\(data.count)".utf8))
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Start of the file name of every image of this digitization and mode (older versions of the same page).
    static func imagePrefix(_ request: DigitalPageRequest, mode: DigitalPageMode) -> String {
        "img-\(request.digitizationID.uuidString)-\(mode.rawValue)-"
    }

    static func imageKey(_ request: DigitalPageRequest, mode: DigitalPageMode) -> String {
        let scale = displayScale(for: request.input)
        return "\(request.digitizationID.uuidString)-\(mode.rawValue)-\(contentHash(of: request.input))"
            + "-v\(DigitalPageBuilder.version)-s\(scale)"
    }

    static func pdfKey(_ requests: [DigitalPageRequest]) -> String {
        let pages = requests.map { "\($0.digitizationID.uuidString)-\(contentHash(of: $0.input))" }.joined(separator: ",")
        let digest = SHA256.hash(data: Data(pages.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-n\(requests.count)-v\(DigitalPageBuilder.version)"
    }

    // MARK: Building

    /// Longest side of a stored display image in pixels (photos are larger than any screen needs).
    static let maxImageSide = 3000
    /// JPEG quality of the display images.
    static let imageQuality = 0.9

    /// The display image of a page as a JPEG file (built on first use). The finished file is always written to the
    /// cache, even if the caller was cancelled meanwhile, so that coming back to the page does not build it again.
    @concurrent
    func imageFile(for request: DigitalPageRequest, mode: DigitalPageMode) async throws -> URL {
        let url = directory.appendingPathComponent("img-\(Self.imageKey(request, mode: mode)).jpg")
        if Self.touchIfExists(url) { return url }
        try Task.checkCancellation()
        let prefix = Self.imagePrefix(request, mode: mode)
        let scale = Self.displayScale(for: request.input)
        return try await imageGate.run {
            // Cancelled while waiting for the slot, or built by an earlier request in the meantime.
            try Task.checkCancellation()
            if Self.touchIfExists(url) { return url }
            let image = try DigitalPageBuilder.makeImage(request.input, mode: mode, scale: scale, sources: self.sources)
            guard let data = Self.encodedImage(image) else { throw DigitalPageError.renderingFailed }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            Self.removeSuperseded(prefix: prefix, keeping: url, in: self.directory)
            try Task.checkCancellation()
            return url
        }
    }

    /// The PDF of the given pages (original look plus invisible text layer) as a file named `fileName`.
    /// Uses its own opened originals, so that a whole import does not stay in memory afterwards.
    @concurrent
    func pdfFile(for requests: [DigitalPageRequest], title: String, fileName: String) async throws -> URL {
        let folder = directory.appendingPathComponent("pdf-\(Self.pdfKey(requests))", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        if Self.touchIfExists(url) {
            Self.touch(folder)
            return url
        }
        try Task.checkCancellation()
        let inputs = requests.map(\.input)
        return try await pdfGate.run {
            try Task.checkCancellation()
            if Self.touchIfExists(url) { return url }
            let data = try DigitalPageBuilder.makePDF(inputs, title: title, sources: DigitalPageSources())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return url
        }
    }

    /// JPEG data of `image`: flattened onto white (JPEG has no transparency) and scaled down so that its longest
    /// side is at most `maxSide` pixels.
    static func encodedImage(_ image: CGImage, maxSide: Int = maxImageSide, quality: Double = imageQuality) -> Data? {
        let longest = max(image.width, image.height)
        let factor = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Deletes the files of earlier versions of a page (same digitization and mode), keeping `keep`.
    static func removeSuperseded(prefix: String, keeping keep: URL, in directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name != keep.lastPathComponent {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: File names

    /// "<name> – digital.pdf", safe as a file name.
    static func pdfFileName(base: String, suffix: String? = nil) -> String {
        let cleaned = sanitized(base)
        let parts = [cleaned.isEmpty ? "Seite" : cleaned] + (suffix.map { [sanitized($0)] } ?? []) + ["digital"]
        return parts.joined(separator: " – ") + ".pdf"
    }

    static func sanitized(_ name: String) -> String {
        var base = name
        // The ending of the original file (the PDF gets its own).
        for ending in [".pdf", ".jpg", ".jpeg", ".png", ".heic"] where base.lowercased().hasSuffix(ending) {
            base = String(base.dropLast(ending.count))
        }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = base.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String(cleaned.prefix(80))
    }

    // MARK: Cleaning

    private static func touchIfExists(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        touch(url)
        return true
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Deletes entries not used for `maxAge`, then the oldest ones until the folder fits in `maxBytes`.
    static func prune(_ directory: URL, now: Date = Date(), maxAge: TimeInterval = maxAge, maxBytes: Int = maxBytes) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = items.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date, size(of: url))
        }
        entries.removeAll { entry in
            guard now.timeIntervalSince(entry.date) > maxAge else { return false }
            try? manager.removeItem(at: entry.url)
            return true
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func size(of url: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        var total = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in enumerator {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        }
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return total
    }
}

// MARK: - Store in the environment

private struct DigitalPageStoreKey: EnvironmentKey {
    static let defaultValue: DigitalPageStore? = nil
}

extension EnvironmentValues {
    /// The app's digital page store. Always set by `StudyHelperApp`; nil only in previews without setup.
    var digitalPageStore: DigitalPageStore? {
        get { self[DigitalPageStoreKey.self] }
        set { self[DigitalPageStoreKey.self] = newValue }
    }
}

// MARK: - Mode per subject

extension DigitalPageMode {
    var germanName: String {
        switch self {
        case .handwriting: "Handschrift"
        case .textLayer: "Textebene"
        }
    }
}

/// The chosen layer is remembered per subject (`@AppStorage("digitalPageMode.<subjectID>")`).
enum DigitalPageModePreference {
    static func key(for subjectID: UUID?) -> String {
        "digitalPageMode.\(subjectID?.uuidString ?? "none")"
    }

    static func mode(for subjectID: UUID?, defaults: UserDefaults = .standard) -> DigitalPageMode {
        defaults.string(forKey: key(for: subjectID)).flatMap(DigitalPageMode.init(rawValue:)) ?? .handwriting
    }

    static func set(_ mode: DigitalPageMode, for subjectID: UUID?, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key(for: subjectID))
    }
}
