import Foundation

/// Why a model answer could not be turned into the expected type.
public enum StructuredOutputError: Error, Equatable, Sendable {
    /// No `{` or `[` in the text.
    case noJSON
    /// JSON starts but is not closed (answer cut off, e.g. by the output limit).
    case truncated
    case invalidJSON(String)
    case typeMismatch(String)

    /// German text for the UI and the request log.
    public var message: String {
        switch self {
        case .noJSON: return "Die Antwort enthält kein JSON."
        case .truncated: return "Die Antwort wurde abgeschnitten (JSON nicht abgeschlossen)."
        case .invalidJSON(let detail): return "Die Antwort enthält ungültiges JSON: \(detail)"
        case .typeMismatch(let detail): return "Die Antwort hat nicht das erwartete Format: \(detail)"
        }
    }
}

/// Extracts and decodes the JSON value of a model answer. Never crashes, whatever the text is.
public enum StructuredOutput {
    /// The outermost JSON object or array in `text` (code fences and surrounding prose are ignored).
    public static func extractJSON(from text: String) -> Result<String, StructuredOutputError> {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return .failure(.noJSON) }
        var stack: [Unicode.Scalar] = []
        var inString = false
        var escaped = false
        var index = start
        while index < scalars.count {
            let c = scalars[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    guard let expected = stack.popLast(), expected == c else {
                        return .failure(.invalidJSON("Unerwartetes Zeichen „\(c)“."))
                    }
                    if stack.isEmpty {
                        var view = String.UnicodeScalarView()
                        view.append(contentsOf: scalars[start...index])
                        return .success(String(view))
                    }
                default: break
                }
            }
            index += 1
        }
        return .failure(.truncated)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> Result<T, StructuredOutputError> {
        let json: String
        switch extractJSON(from: text) {
        case .success(let value): json = value
        case .failure(let error): return .failure(error)
        }
        let data = Data(json.utf8)
        do {
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch let error as DecodingError {
            switch error {
            case .dataCorrupted(let context):
                // Syntax errors are corrupted data; check syntax separately to tell them from content errors.
                if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                    return .failure(.invalidJSON(context.debugDescription))
                }
                return .failure(.typeMismatch(describe(error)))
            default:
                return .failure(.typeMismatch(describe(error)))
            }
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : " (\(p))"
        }
        switch error {
        case .keyNotFound(let key, let context): return "Feld „\(key.stringValue)“ fehlt\(path(context))"
        case .typeMismatch(_, let context): return "falscher Typ\(path(context))"
        case .valueNotFound(_, let context): return "Wert fehlt\(path(context))"
        case .dataCorrupted(let context): return context.debugDescription
        @unknown default: return "unbekannter Fehler"
        }
    }
}
