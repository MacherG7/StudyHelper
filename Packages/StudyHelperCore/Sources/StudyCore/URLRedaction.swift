import Foundation

/// Keeps credentials out of logs and messages: user name, password, query and fragment of a URL can carry secrets
/// (`http://user:pass@host`, `?key=...`), so they are removed wherever a URL is shown or stored.
public enum URLRedaction {
    /// `text` as a URL without credentials, query and fragment. Works on text that is not a valid URL, too.
    public static func redact(url text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = result.firstIndex(where: { $0 == "?" || $0 == "#" }) { result = String(result[..<cut]) }
        let prefixEnd: String.Index
        if let range = result.range(of: "://") { prefixEnd = range.upperBound } else { prefixEnd = result.startIndex }
        let rest = result[prefixEnd...]
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            result = String(result[..<prefixEnd]) + String(authority[authority.index(after: at)...])
                + String(rest[authorityEnd...])
        }
        return result
    }

    /// Every `http(s)://...` URL inside `text` redacted (for error messages and exports).
    public static func redact(in text: String) -> String {
        guard text.contains("://"), let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>]+"#)
        else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += redact(url: String(text[range]))
            last = range.upperBound
        }
        result += text[last...]
        return result
    }
}
