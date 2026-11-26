import Foundation

// Compact German chat text of a recognition report (pasted into a chat with the developer's assistant).

extension RecognitionReport {
    /// Marker line before the one-line JSON of the entries.
    public static let chatJSONMarker = "JSON-Kurzform:"

    /// Maximum length of recognized/context texts in the chat text (expected text is never truncated).
    static let chatTextLimit = 80

    /// Compact German Markdown: header, one block per import, one line per entry, then `JSON-Kurzform:` and
    /// the entries as one-line compact JSON (without images unless `includeImages`).
    public func chatText(includeImages: Bool = false) -> String {
        var out: [String] = []

        var header = "StudyHelper-Erkennungsfehler"
        if !app.version.isEmpty {
            header += " · App \(app.version)"
            if let commit = app.commit, !commit.isEmpty { header += " (\(commit))" }
        }
        header += " · \(Self.germanDate(createdAt))"
        out.append(header)

        var remaining = entries
        for source in imports {
            let own = remaining.filter { $0.importID == source.id }
            remaining.removeAll { $0.importID == source.id }
            guard !own.isEmpty else { continue }
            var title = source.fileName.isEmpty ? "Quelle" : source.fileName
            var details = [source.kindDisplayName]
            if let pages = source.pageCount { details.append(pages == 1 ? "1 Seite" : "\(pages) Seiten") }
            title += " (\(details.joined(separator: ", ")))"
            out.append(title)
            out.append(contentsOf: own.map { Self.chatLine(for: $0) })
        }
        if !remaining.isEmpty {
            if !imports.isEmpty { out.append("Unbekannte Quelle") }
            out.append(contentsOf: remaining.map { Self.chatLine(for: $0) })
        }

        out.append(Self.chatJSONMarker)
        out.append(compactEntriesJSON(includeImages: includeImages))
        return out.joined(separator: "\n")
    }

    /// The entries as one-line compact JSON; nil values are left out.
    func compactEntriesJSON(includeImages: Bool) -> String {
        let list = includeImages ? entries : entries.map(\.withoutImage)
        let encoder = Self.makeEncoder(pretty: false, omitNulls: true)
        guard let data = try? encoder.encode(list), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    /// Reads the entries from the one-line JSON after `JSON-Kurzform:` in a pasted chat text.
    public static func entries(fromChatText text: String) -> [RecognitionReportEntry]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix(chatJSONMarker) }) else { return nil }
        var json = String(lines[markerIndex].dropFirst(chatJSONMarker.count)).trimmingCharacters(in: .whitespaces)
        if json.isEmpty, markerIndex + 1 < lines.count { json = lines[markerIndex + 1] }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? makeDecoder().decode([RecognitionReportEntry].self, from: data)
    }

    // MARK: Formatting

    static func chatLine(for entry: RecognitionReportEntry) -> String {
        var parts = ["S. \(entry.page)"]
        parts.append(entry.source == .correction ? "\(entry.kind.displayName) (Korrektur)" : entry.kind.displayName)

        var showArea = true
        switch entry.kind {
        case .order:
            showArea = false
            let moved = entry.recognized ?? entry.lines.map(\.text).joined(separator: "\n")
            if let after = entry.after {
                parts.append("\(quoted(truncated(moved))) gehört hinter \(quoted(truncated(after.text)))")
            } else if !moved.isEmpty {
                parts.append(quoted(truncated(moved)))
            }
            if let expected = entry.expected { parts.append("erwartet \(quoted(oneLine(expected)))") }
        case .missing:
            if let recognized = entry.recognized { parts.append("erkannt \(quoted(truncated(recognized)))") }
            parts.append(areaText(entry.rect))
            showArea = false
            if let expected = entry.expected { parts.append("erwartet \(quoted(oneLine(expected)))") }
        default:
            switch (entry.recognized, entry.expected) {
            case let (recognized?, expected?):
                parts.append("\(quoted(truncated(recognized))) → \(quoted(oneLine(expected)))")
            case let (recognized?, nil):
                parts.append(quoted(truncated(recognized)))
            case let (nil, expected?):
                parts.append("erwartet \(quoted(oneLine(expected)))")
            case (nil, nil):
                break
            }
        }
        if showArea { parts.append(areaText(entry.rect)) }
        if let note = entry.note, !note.isEmpty { parts.append("Notiz: \(oneLine(note))") }
        return "- " + parts.joined(separator: " · ")
    }

    static func areaText(_ rect: NormalizedRect) -> String {
        "Bereich x \(number(rect.x)) y \(number(rect.y)) b \(number(rect.width)) h \(number(rect.height))"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func quoted(_ text: String) -> String { "„\(text)“" }

    /// Newlines become " ⏎ " so one entry stays on one line.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    static func truncated(_ text: String, limit: Int = chatTextLimit) -> String {
        let flat = oneLine(text)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// dd.MM.yyyy in UTC (deterministic).
    static func germanDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }
}
