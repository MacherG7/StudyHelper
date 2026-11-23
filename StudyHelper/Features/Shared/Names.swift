import StudyCore
import StudyData
import SwiftUI
import UIKit

// German display names and small view helpers for the model enums (SPEC: "Die App-Sprache ist Deutsch").

extension HighlightKind {
    var germanName: String {
        switch self {
        case .underline: "Unterstrichen"
        case .doubleUnderline: "Doppelt unterstrichen"
        case .bold: "Fett"
        case .coloredPen: "Farbiger Stift"
        case .highlighter: "Textmarker"
        case .boxed: "Umrandet"
        case .circled: "Eingekreist"
        case .uppercase: "Großbuchstaben"
        }
    }

    var symbolName: String {
        switch self {
        case .underline: "underline"
        case .doubleUnderline: "underline"
        case .bold: "bold"
        case .coloredPen: "pencil.tip"
        case .highlighter: "highlighter"
        case .boxed: "rectangle"
        case .circled: "circle"
        case .uppercase: "textformat.size.larger"
        }
    }
}

extension HighlightMeaning {
    var germanName: String {
        switch self {
        case .heading: "Überschrift"
        case .term: "Fachbegriff"
        case .definition: "Definition"
        case .rule: "Merksatz"
        case .formula: "Formel"
        case .important: "Wichtig"
        }
    }
}

extension ConfidenceStatus {
    var germanName: String {
        switch self {
        case .confident: "sicher"
        case .uncertain: "unsicher"
        case .illegible: "unleserlich"
        }
    }
}

extension RecognitionMethod {
    var germanName: String {
        switch self {
        case .vision: "Vision-Texterkennung"
        case .visionDocument: "Vision-Dokumenterkennung"
        case .embeddedPDFText: "Eingebetteter PDF-Text"
        case .goodnotesInkLayers: "Goodnotes-Farbebenen"
        case .aiModel: "KI-Modell"
        case .manual: "Manuell"
        }
    }
}

extension ImportKind {
    var germanName: String {
        switch self {
        case .photo: "Fotos"
        case .scan: "Scan"
        case .pdf: "PDF"
        case .goodnotes: "Goodnotes-Export"
        }
    }

    var symbolName: String {
        switch self {
        case .photo: "photo"
        case .scan: "doc.viewfinder"
        case .pdf: "doc.richtext"
        case .goodnotes: "pencil.and.scribble"
        }
    }

    /// Imports whose pages come from a stored PDF (as opposed to stored images).
    var isPDF: Bool { self == .pdf || self == .goodnotes }
}

// MARK: Colors

extension RGBColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    /// Rough German color name for VoiceOver ("gelb", "rot", ...).
    var germanName: String {
        let candidates: [(String, RGBColor)] = [
            ("schwarz", .black), ("weiß", .white),
            ("gelb", RGBColor(hex: "#FFEB3B") ?? .white), ("grün", RGBColor(hex: "#4CAF50") ?? .black),
            ("rot", RGBColor(hex: "#D32F2F") ?? .black), ("blau", RGBColor(hex: "#1976D2") ?? .black),
            ("orange", RGBColor(hex: "#FF9800") ?? .black), ("violett", RGBColor(hex: "#7B1FA2") ?? .black),
            ("rosa", RGBColor(hex: "#F06292") ?? .black), ("grau", RGBColor(hex: "#9E9E9E") ?? .black),
        ]
        return candidates.min { distance(to: $0.1) < distance(to: $1.1) }?.0 ?? "farbig"
    }
}

/// Colors offered when editing a highlight.
enum HighlightPalette {
    static let colors: [(name: String, color: RGBColor)] = [
        ("Gelb", RGBColor(hex: "#FFEB3B") ?? .white),
        ("Grün", RGBColor(hex: "#4CAF50") ?? .black),
        ("Rot", RGBColor(hex: "#D32F2F") ?? .black),
        ("Blau", RGBColor(hex: "#1976D2") ?? .black),
        ("Orange", RGBColor(hex: "#FF9800") ?? .black),
        ("Violett", RGBColor(hex: "#7B1FA2") ?? .black),
    ]
}

// MARK: Line status

/// What the user sees for a line: sure, to be checked, illegible or already corrected.
enum LineDisplayStatus {
    case confident, uncertain, illegible, corrected

    var germanName: String {
        switch self {
        case .confident: "sicher"
        case .uncertain: "unsicher"
        case .illegible: "unleserlich"
        case .corrected: "von dir korrigiert"
        }
    }

    var symbolName: String? {
        switch self {
        case .confident: nil
        case .uncertain: "exclamationmark.triangle.fill"
        case .illegible: "questionmark.circle.fill"
        case .corrected: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .confident: .secondary
        case .uncertain: .orange
        case .illegible: .red
        case .corrected: .green
        }
    }
}

extension RecognizedLine {
    var displayStatus: LineDisplayStatus {
        if isUserCorrected { return .corrected }
        if status == .illegible { return .illegible }
        if needsReview { return .uncertain }
        return .confident
    }
}

// MARK: Highlights per line

extension RecognizedHighlight {
    /// True if the highlight belongs to `line` (by word references, else by geometry).
    func applies(to line: RecognizedLine) -> Bool {
        if !words.isEmpty { return words.contains { $0.lineID == line.id } }
        return line.rect.coverage(by: rect) > 0.5
    }

    /// "Chloroplasten, Textmarker, gelb, Wichtig" – spoken by VoiceOver.
    var spokenDescription: String {
        var parts = [text.isEmpty ? "Markierung" : text, kind.germanName]
        if let color, kind == .highlighter || kind == .coloredPen { parts.append(color.germanName) }
        if let suggestedMeaning { parts.append(suggestedMeaning.germanName) }
        return parts.joined(separator: ", ")
    }

    /// Short visible description: "Textmarker · Wichtig".
    var visibleDescription: String {
        [kind.germanName, suggestedMeaning?.germanName].compactMap { $0 }.joined(separator: " · ")
    }

    var displayColor: Color {
        if let color { return color.swiftUIColor }
        switch kind {
        case .highlighter: return Color(red: 1, green: 0.92, blue: 0.23)
        case .underline, .doubleUnderline: return .blue
        case .circled: return .purple
        case .boxed: return .teal
        case .bold: return .indigo
        case .coloredPen: return .red
        case .uppercase: return .mint
        }
    }
}

// MARK: Dates

extension Date {
    var germanShort: String {
        formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "de_DE")))
    }
}
