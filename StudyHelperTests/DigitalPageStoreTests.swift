import Foundation
import ImageIO
import PDFKit
import StudyCore
import StudyData
import StudyImport
import SwiftData
import Testing
import UIKit
@testable import StudyHelper

@Suite("Digitale Seite: Zwischenspeicher, Schlüssel und Ebene je Fach")
@MainActor
struct DigitalPageStoreTests {
    /// The repository retains the container, so keeping it keeps the models usable.
    private struct Seeded {
        let repository: StudyRepository
        let subject: Subject
        let batch: ImportBatch
        let source: Source
    }

    private func seeded(withVersions: Bool = false) throws -> Seeded {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository, withVersions: withVersions)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        return Seeded(repository: repository, subject: subject, batch: batch, source: source)
    }

    private func temporaryStore() -> (DigitalPageStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigitalPageTests-\(UUID().uuidString)")
        return (DigitalPageStore(directory: folder, pruneAtStart: false), folder)
    }

    private func textKey(_ source: Source) throws -> String {
        DigitalPageStore.imageKey(try DigitalPageRequest.make(source: source), mode: .textLayer)
    }

    @Test("Der Schlüssel ist für denselben Stand gleich und hängt von der Ebene ab")
    func keyIsStable() throws {
        let seed = try seeded()
        let first = try textKey(seed.source)
        #expect(try textKey(seed.source) == first)
        let request = try DigitalPageRequest.make(source: seed.source)
        #expect(DigitalPageStore.imageKey(request, mode: .handwriting) != first)
        #expect(first.contains(request.digitizationID.uuidString))
        #expect(first.contains("v\(DigitalPageBuilder.version)"))
    }

    @Test("Der Schlüssel ändert sich nach einer Korrektur")
    func keyChangesAfterCorrection() throws {
        let seed = try seeded()
        let before = try textKey(seed.source)
        let line = try #require(seed.source.currentDigitization?.lines.first { $0.order == 2 })
        try seed.repository.correctLine(source: seed.source, lineID: line.id, newText: "Chlorophyll ist der grüne Blattfarbstoff")
        #expect(try textKey(seed.source) != before)
    }

    @Test("Der Schlüssel ändert sich nach dem Wiederherstellen einer Version")
    func keyChangesAfterRestore() throws {
        let seed = try seeded(withVersions: true)
        let current = try textKey(seed.source)
        let first = try #require(seed.source.sortedDigitizations.first)
        #expect(!first.isCurrent)
        try seed.repository.restoreVersion(first)
        let restored = try textKey(seed.source)
        #expect(restored != current)
        #expect(try DigitalPageRequest.make(source: seed.source).digitizationID == first.id)
    }

    @Test("Die Ebene wird je Fach gemerkt")
    func modePerSubject() throws {
        let defaults = try #require(UserDefaults(suiteName: "StudyHelperTests-\(UUID().uuidString)"))
        let biology = UUID(), german = UUID()
        #expect(DigitalPageModePreference.mode(for: biology, defaults: defaults) == .handwriting)
        DigitalPageModePreference.set(.textLayer, for: biology, defaults: defaults)
        #expect(DigitalPageModePreference.mode(for: biology, defaults: defaults) == .textLayer)
        #expect(DigitalPageModePreference.mode(for: german, defaults: defaults) == .handwriting)
        DigitalPageModePreference.set(.textLayer, for: german, defaults: defaults)
        DigitalPageModePreference.set(.handwriting, for: biology, defaults: defaults)
        #expect(DigitalPageModePreference.mode(for: german, defaults: defaults) == .textLayer)
        #expect(DigitalPageModePreference.mode(for: biology, defaults: defaults) == .handwriting)
        #expect(DigitalPageModePreference.key(for: biology) != DigitalPageModePreference.key(for: german))
        #expect(DigitalPageModePreference.key(for: biology) == "digitalPageMode.\(biology.uuidString)")
    }

    @Test("Der Speicher erzeugt ein Bild der Textebene und liefert es beim zweiten Mal aus dem Zwischenspeicher")
    func producesImage() async throws {
        let seed = try seeded()
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try DigitalPageRequest.make(source: seed.source)

        let url = try await store.imageFile(for: request, mode: .textLayer)
        let image = try #require(UIImage(contentsOfFile: url.path))
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

        #expect(url.pathExtension == "jpg")
        let head = try Data(contentsOf: url).prefix(3)
        #expect(Array(head) == [0xFF, 0xD8, 0xFF], "JPEG statt PNG")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let created = try #require(attributes[.modificationDate] as? Date)
        let again = try await store.imageFile(for: request, mode: .textLayer)
        #expect(again == url)
        let attributesAgain = try FileManager.default.attributesOfItem(atPath: again.path)
        #expect(try #require(attributesAgain[.modificationDate] as? Date) >= created)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test("Eine Korrektur erzeugt eine neue Datei und löscht die alte derselben Seite")
    func correctionBuildsNewFile() async throws {
        let seed = try seeded()
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await store.imageFile(for: DigitalPageRequest.make(source: seed.source), mode: .textLayer)
        let line = try #require(seed.source.currentDigitization?.lines.first { $0.order == 0 })
        try seed.repository.correctLine(source: seed.source, lineID: line.id, newText: "Photosynthese")
        let after = try await store.imageFile(for: DigitalPageRequest.make(source: seed.source), mode: .textLayer)
        #expect(before != after)
        #expect(!FileManager.default.fileExists(atPath: before.path), "die veraltete Datei ist weg")
        #expect(FileManager.default.fileExists(atPath: after.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [after.lastPathComponent])
    }

    @Test("Beim Schreiben bleiben Dateien anderer Seiten und der anderen Ebene erhalten")
    func supersededOnlyOfSamePageAndMode() async throws {
        let seed = try seeded()
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try DigitalPageRequest.make(source: seed.source)
        let handwriting = try await store.imageFile(for: request, mode: .handwriting)
        let text = try await store.imageFile(for: request, mode: .textLayer)
        let other = folder.appendingPathComponent("img-\(UUID().uuidString)-textLayer-abc.jpg")
        try Data([1]).write(to: other)
        let line = try #require(seed.source.currentDigitization?.lines.first { $0.order == 0 })
        try seed.repository.correctLine(source: seed.source, lineID: line.id, newText: "Photosynthese")
        let corrected = try await store.imageFile(for: DigitalPageRequest.make(source: seed.source), mode: .textLayer)
        #expect(!FileManager.default.fileExists(atPath: text.path))
        #expect(FileManager.default.fileExists(atPath: corrected.path))
        #expect(FileManager.default.fileExists(atPath: handwriting.path), "andere Ebene bleibt")
        #expect(FileManager.default.fileExists(atPath: other.path), "andere Seite bleibt")
    }

    /// A photo page (no PDF) of the given pixel size.
    private func photoRequest(width: Int, height: Int) throws -> DigitalPageRequest {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = try #require(photo.jpegData(compressionQuality: 0.8))
        return DigitalPageRequest(
            digitizationID: UUID(), input: DigitalPageInput(background: .image(data: data), lines: [], highlights: []))
    }

    @Test("Ein großes Foto wird als JPEG mit höchstens 3000 Pixeln Kantenlänge gespeichert")
    func largePhotoIsBoundedJPEG() async throws {
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = try photoRequest(width: 4200, height: 2800)
        let url = try await store.imageFile(for: request, mode: .textLayer)
        #expect(url.pathExtension == "jpg")
        #expect(Array(try Data(contentsOf: url).prefix(3)) == [0xFF, 0xD8, 0xFF])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) == DigitalPageStore.maxImageSide)
        #expect(width == 3000 && height == 2000, "Seitenverhältnis bleibt")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 3 * 1024 * 1024)
    }

    @Test("Kleine Bilder werden nicht skaliert; Transparenz wird auf Weiß gesetzt")
    func encodingKeepsSmallImagesAndFlattens() throws {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        let data = try #require(DigitalPageStore.encodedImage(image))
        let decoded = try #require(UIImage(data: data)?.cgImage)
        #expect(decoded.width == 40 && decoded.height == 20)
        let pixel = try #require(UIImage(data: data)).pixelColor(x: 5, y: 5)
        #expect(pixel.r > 240 && pixel.g > 240 && pixel.b > 240, "transparent wird weiß, nicht schwarz")
    }

    @Test("Die Warteschlange führt nur eine Arbeit zugleich aus; die neueste Anfrage kommt zuerst")
    func gateLatestFirst() async throws {
        let gate = BuildGate()
        let order = Order()
        let release = AsyncGate()
        let running = Task { try await gate.run { order.append("held"); release.wait() } }
        while order.items.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let older = Task { try await gate.run { order.append("older") } }
        try await Task.sleep(for: .milliseconds(50))
        let newer = Task { try await gate.run { order.append("newer") } }
        try await Task.sleep(for: .milliseconds(50))
        release.open()
        try await running.value
        try await older.value
        try await newer.value
        #expect(order.items == ["held", "newer", "older"])
    }

    @Test("Ein abgebrochener Wartender verlässt die Schlange, ohne zu arbeiten")
    func gateCancelledWaiterSkipped() async throws {
        let gate = BuildGate()
        let order = Order()
        let release = AsyncGate()
        let running = Task { try await gate.run { order.append("held"); release.wait() } }
        while order.items.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let stale = Task { try await gate.run { order.append("stale") } }
        try await Task.sleep(for: .milliseconds(50))
        stale.cancel()
        await #expect(throws: CancellationError.self) { try await stale.value }
        release.open()
        try await running.value
        try await gate.run { order.append("after") }
        #expect(order.items == ["held", "after"])
    }

    @Test("Der Speicher erzeugt ein gültiges PDF mit dem Namen des Imports")
    func producesPDF() async throws {
        let seed = try seeded()
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let requests = try DigitalPageRequest.all(of: seed.batch)
        #expect(requests.count == 1)
        let name = DigitalPageStore.pdfFileName(base: DigitalPageStore.baseName(of: seed.batch))
        #expect(name == "Fotosynthese – digital.pdf")

        let url = try await store.pdfFile(for: requests, title: "Fotosynthese", fileName: name)
        #expect(url.lastPathComponent == name)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("Fotosynthese") == true, "die Textebene ist durchsuchbar")
        let again = try await store.pdfFile(for: requests, title: "Fotosynthese", fileName: name)
        #expect(again == url)
    }

    @Test("Das PDF einer einzelnen Version wird mit dem Text dieser Version gebaut")
    func versionPDF() async throws {
        let seed = try seeded(withVersions: true)
        let (store, folder) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try #require(seed.source.sortedDigitizations.first)
        let request = try DigitalPageRequest.make(source: seed.source, digitization: old)
        #expect(request.digitizationID == old.id)
        let url = try await store.pdfFile(for: [request], title: "Version 1", fileName: "V1 – digital.pdf")
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("überarbeitet") == false)
    }

    @Test("Dateinamen werden bereinigt")
    func fileNames() {
        #expect(DigitalPageStore.pdfFileName(base: "Bio/Ch:1?.pdf") == "Bio-Ch-1- – digital.pdf")
        #expect(DigitalPageStore.pdfFileName(base: "  ") == "Seite – digital.pdf")
        #expect(DigitalPageStore.pdfFileName(base: "Heft", suffix: "Version 2") == "Heft – Version 2 – digital.pdf")
        #expect(DigitalPageStore.sanitized(String(repeating: "a", count: 200)).count == 80)
    }

    @Test("Alte und überzählige Dateien werden aufgeräumt")
    func pruning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigitalPagePrune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = FileManager.default
        func write(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(count: bytes).write(to: url)
            try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let old = try write("old.png", bytes: 10, age: 40 * 24 * 3600)
        let fresh = try write("fresh.png", bytes: 10, age: 60)
        DigitalPageStore.prune(folder)
        #expect(!manager.fileExists(atPath: old.path) && manager.fileExists(atPath: fresh.path))

        let oldest = try write("a.png", bytes: 600, age: 3000)
        let newest = try write("b.png", bytes: 600, age: 10)
        DigitalPageStore.prune(folder, maxBytes: 1000)
        #expect(!manager.fileExists(atPath: oldest.path) && manager.fileExists(atPath: newest.path))
    }
}

/// Thread-safe list of events for the gate tests.
private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var items: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

/// Blocks a synchronous work item until `open()` (the work runs on a pool thread, never on the main actor).
private final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

private extension UIImage {
    func pixelColor(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        guard let cgImage, let provider = cgImage.dataProvider, let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let offset = y * cgImage.bytesPerRow + x * (cgImage.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
