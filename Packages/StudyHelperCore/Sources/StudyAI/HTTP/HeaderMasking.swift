import Foundation

/// Keeps keys out of logs: values of secret headers become "***".
public enum HeaderMasking {
    public static let secretHeaders: Set<String> = [
        "authorization", "x-api-key", "api-key", "openai-api-key", "cookie", "proxy-authorization",
    ]

    public static func isSecret(_ name: String) -> Bool { secretHeaders.contains(name.lowercased()) }

    public static func masked(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            result[pair.key] = isSecret(pair.key) ? "***" : pair.value
        }
    }

    /// A request as text for logs: method, URL, masked headers (sorted), body. Binary bodies are summarized.
    public static func render(_ request: URLRequest) -> String {
        var lines = ["\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"]
        for (name, value) in masked(request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            lines.append("\(name): \(value)")
        }
        if let body = request.httpBody {
            lines.append("")
            lines.append(String(data: body, encoding: .utf8) ?? "<\(body.count) Bytes>")
        }
        return lines.joined(separator: "\n")
    }
}
