import Foundation

/// A generated fixture: PDF bytes plus the matching ground truth.
public struct GeneratedFixture: Sendable {
    public let pdfData: Data
    /// Encoded ground truth (`.sortedKeys`, `.prettyPrinted`), exactly what `<name>.truth.json` contains.
    public let truthData: Data
    public let truth: GoodnotesGroundTruth
}

/// The synthetic Goodnotes-like test PDFs that ship as package resources.
///
/// They mimic the structure of Goodnotes exports (see docs/SPEC.md, "Goodnotes-Import") but are generated
/// from code, never taken from real notes. Regenerate with
/// `swift run --package-path Packages/StudyHelperCore make-fixtures`.
public enum GoodnotesFixture: String, CaseIterable, Sendable {
    /// 3 pages, A4, Goodnotes "editable" structure (Ink / FreeText / Stamp annotations).
    case fotosyntheseEditable = "Fotosynthese_bearbeitbar"
    /// Reduced counterpart of `fotosyntheseEditable`: same page count and size, no annotations, text layer.
    case fotosyntheseReduced = "Fotosynthese_reduziert"
    /// Reduced PDF with 1 page (page count differs from the Fotosynthese files).
    case andereNotizReduced = "Andere_Notiz_reduziert"
    /// Reduced PDF with 3 pages in US Letter (page size differs from the Fotosynthese files).
    case andereGroesseReduced = "Andere_Groesse_reduziert"

    public var fileName: String { rawValue + ".pdf" }
    public var truthFileName: String { rawValue + ".truth.json" }

    /// The committed PDF inside the module bundle.
    public var url: URL { Self.resourceURL(fileName) }
    /// The committed ground-truth JSON inside the module bundle.
    public var truthURL: URL { Self.resourceURL(truthFileName) }

    /// Decodes the committed ground-truth JSON.
    public func loadTruth() throws -> GoodnotesGroundTruth {
        try GoodnotesGroundTruth.decode(from: Data(contentsOf: truthURL))
    }

    /// The description from which PDF and truth are generated.
    public var spec: GoodnotesFixtureSpec {
        typealias S = GoodnotesFixtureSpec
        switch self {
        case .fotosyntheseEditable:
            return S(name: rawValue, title: "Fotosynthese (bearbeitbar, synthetisch)", variant: .editable,
                     content: .fotosynthese, pageWidth: S.a4Width, pageHeight: S.a4Height, ocrSubstitutions: [:])
        case .fotosyntheseReduced:
            return S(name: rawValue, title: "Fotosynthese (reduziert, synthetisch)", variant: .reduced,
                     content: .fotosynthese, pageWidth: S.a4Width, pageHeight: S.a4Height,
                     ocrSubstitutions: FixtureContent.defaultOCRErrors)
        case .andereNotizReduced:
            return S(name: rawValue, title: "Andere Notiz (reduziert, synthetisch)", variant: .reduced,
                     content: .andereNotiz, pageWidth: S.a4Width, pageHeight: S.a4Height, ocrSubstitutions: [:])
        case .andereGroesseReduced:
            return S(name: rawValue, title: "Andere Größe (reduziert, synthetisch)", variant: .reduced,
                     content: .andereGroesse, pageWidth: S.letterWidth, pageHeight: S.letterHeight,
                     ocrSubstitutions: [:])
        }
    }

    /// Generates PDF and ground truth in memory. Deterministic: two calls return identical bytes.
    public func generate() throws -> GeneratedFixture {
        try generate(includeTextLayer: true)
    }

    /// Like `generate()`; `includeTextLayer: false` leaves the invisible text out of reduced PDFs (test aid).
    func generate(includeTextLayer: Bool) throws -> GeneratedFixture {
        let spec = self.spec
        let rendered = PDFRendering.render(spec: spec, pages: FixtureContent.pages(for: spec),
                                           includeTextLayer: includeTextLayer)
        return GeneratedFixture(pdfData: rendered.pdf, truthData: try rendered.truth.jsonData(),
                                truth: rendered.truth)
    }

    /// PostScript name of the font that currently provides the handwriting outlines.
    public static var handwritingFontName: String { HandwritingFont.resolvedName }
    /// Version string of that font.
    public static var handwritingFontVersion: String { HandwritingFont.resolvedVersion }
    /// The font the committed fixtures are made with (`Noteworthy-Light`).
    public static var preferredHandwritingFontName: String { HandwritingFont.preferredName }

    /// Generates every fixture.
    public static func generateAll() throws -> [(fixture: GoodnotesFixture, result: GeneratedFixture)] {
        try allCases.map { ($0, try $0.generate()) }
    }

    private static func resourceURL(_ file: String) -> URL {
        // `.copy("Resources")` keeps the folder structure: <bundle>/Resources/Goodnotes/<file>.
        if let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Resources/Goodnotes") {
            return url
        }
        if let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Goodnotes") {
            return url
        }
        return Bundle.module.bundleURL.appendingPathComponent("Resources/Goodnotes/\(file)")
    }
}
