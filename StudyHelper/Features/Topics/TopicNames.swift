import StudyCore
import StudyData
import SwiftUI

// German names, symbols and spoken descriptions for topics and entries.

extension EntryKind {
    /// Singular, e.g. for buttons: "Kernaussage".
    var germanName: String {
        switch self {
        case .keyStatement: "Kernaussage"
        case .term: "Begriff"
        case .rule: "Formel / Regel"
        case .example: "Beispiel"
        case .table: "Tabelle"
        }
    }

    /// Section title in the editor and the topic view.
    var sectionTitle: String {
        switch self {
        case .keyStatement: "Kernaussagen"
        case .term: "Begriffe"
        case .rule: "Formeln, Regeln, Merksätze"
        case .example: "Beispiele"
        case .table: "Tabellen"
        }
    }

    var addTitle: String {
        switch self {
        case .keyStatement: "Kernaussage hinzufügen"
        case .term: "Begriff hinzufügen"
        case .rule: "Formel, Regel oder Merksatz hinzufügen"
        case .example: "Beispiel hinzufügen"
        case .table: "Tabelle hinzufügen"
        }
    }

    /// Title of the sheet for a new entry.
    var newTitle: String {
        switch self {
        case .keyStatement: "Neue Kernaussage"
        case .term: "Neuer Begriff"
        case .rule: "Neue Formel / Regel"
        case .example: "Neues Beispiel"
        case .table: "Neue Tabelle"
        }
    }

    var symbolName: String {
        switch self {
        case .keyStatement: "text.quote"
        case .term: "character.book.closed"
        case .rule: "function"
        case .example: "lightbulb"
        case .table: "tablecells"
        }
    }

    /// Short label of the "Übernehmen als" buttons.
    var takeoverTitle: String {
        switch self {
        case .keyStatement: "Kernaussage"
        case .term: "Begriff"
        case .rule: "Formel"
        case .example: "Beispiel"
        case .table: "Tabelle"
        }
    }

    /// Kinds that can be taken over from text (a table is typed in the editor).
    static let takeoverKinds: [EntryKind] = [.keyStatement, .term, .rule, .example]
}

extension EntryOrigin {
    var germanName: String {
        switch self {
        case .original: "Original"
        case .user: "Eigene Eingabe"
        case .aiSupplement: "KI-Ergänzung"
        }
    }

    /// Spoken: says where the content comes from.
    var spokenName: String {
        switch self {
        case .original: "Herkunft: Original aus dem Lernstoff"
        case .user: "Herkunft: von dir eingegeben"
        case .aiSupplement: "Herkunft: KI-Ergänzung, nicht aus dem Lernstoff"
        }
    }

    var symbolName: String {
        switch self {
        case .original: "doc.text"
        case .user: "person"
        case .aiSupplement: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .original: .blue
        case .user: .gray
        case .aiSupplement: .purple
        }
    }
}

extension TopicOrigin {
    var germanName: String {
        switch self {
        case .manual: "Manuell"
        case .ai: "KI"
        case .mixed: "Gemischt"
        }
    }
}

extension EntryHighlight {
    /// "Textmarker, gelb"
    var germanDescription: String {
        var parts = [kind.germanName]
        if let color, kind == .highlighter || kind == .coloredPen { parts.append(color.germanName) }
        return parts.joined(separator: ", ")
    }
}

/// How a topic is shown in lists and on its screen: ready to learn, confirmed but edited since, or a draft.
enum TopicStatus {
    case ready, modified, draft

    init(_ topic: Topic) {
        self = topic.isReadyForLearning ? .ready : (topic.isConfirmed ? .modified : .draft)
    }

    var germanName: String {
        switch self {
        case .ready: "Bestätigt"
        case .modified: "Geändert"
        case .draft: "Entwurf"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.seal.fill"
        case .modified: "exclamationmark.circle.fill"
        case .draft: "pencil.line"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .modified: .orange
        case .draft: .gray
        }
    }
}

extension TableData {
    /// "Tabelle mit 2 Spalten und 3 Zeilen"
    var germanSummary: String {
        let columns = columnCount
        return "\(columns == 1 ? "1 Spalte" : "\(columns) Spalten") und \(rows.count == 1 ? "1 Zeile" : "\(rows.count) Zeilen")"
    }
}

extension TopicEntry {
    /// The entry as one line of text for lists.
    var displayText: String {
        switch kind {
        case .term:
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if definition.isEmpty { return term.isEmpty ? "(leer)" : term }
            return term.isEmpty ? definition : "\(term): \(definition)"
        case .table:
            guard let data = tableData else { return "Tabelle" }
            let headers = data.headers.filter { !$0.isEmpty }.joined(separator: " · ")
            return headers.isEmpty ? "Tabelle mit \(data.germanSummary)" : "\(headers) (\(data.germanSummary))"
        default:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "(leer)" : value
        }
    }

    /// VoiceOver label of an entry: kind, text, origin, highlight, source.
    func spokenLabel(sourceText: String?, sourceChanged: Bool = false) -> String {
        var parts = ["\(kind.germanName): \(displayText)", origin.spokenName]
        if let highlight { parts.append("Im Original hervorgehoben: \(highlight.germanDescription)") }
        if let sourceText { parts.append(sourceText) }
        if sourceChanged { parts.append("Quelle geändert") }
        if origin == .aiSupplement, let status = supplementStatus {
            switch status {
            case .proposed: parts.append("Noch nicht angenommen")
            case .accepted: parts.append("Angenommen")
            case .rejected: parts.append("Abgelehnt")
            }
        }
        return parts.joined(separator: ". ") + "."
    }
}

extension Source {
    /// "Fotosynthese.jpg · Seite 1"
    var germanTitle: String {
        let name = batch?.originalFileName ?? batch?.kind.germanName ?? "Import"
        return "\(name) · Seite \(pageIndex + 1)"
    }
}
