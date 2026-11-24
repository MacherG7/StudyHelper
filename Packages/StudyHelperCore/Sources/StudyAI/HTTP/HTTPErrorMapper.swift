import Foundation

/// Maps an HTTP error response to `ProviderError`. Tolerates any body (HTML, empty, truncated).
public enum HTTPErrorMapper {
    public enum Style: Sendable { case anthropic, openAI }

    public static func map(
        status: Int, body: Data, headers: [String: String] = [:], style: Style, model: String? = nil
    ) -> ProviderError {
        let parsed = parse(body: body, style: style)
        let message = parsed.message ?? String(data: body.prefix(300), encoding: .utf8) ?? ""
        let retryAfter = retryAfter(from: headers)
        switch style {
        case .anthropic: return anthropic(status, parsed, message, retryAfter, model)
        case .openAI: return openAI(status, parsed, message, retryAfter, model)
        }
    }

    // MARK: Anthropic

    private static func anthropic(
        _ status: Int, _ error: Parsed, _ message: String, _ retryAfter: TimeInterval?, _ model: String?
    ) -> ProviderError {
        if error.errorCode == "enforced_spend_limit_reached" { return .quotaExceeded(message) }
        if error.type == "overloaded_error" || status == 529 { return .overloaded }
        switch status {
        case 401: return .invalidAPIKey
        case 402: return .quotaExceeded(message)
        case 403: return .permissionDenied(message)
        case 404: return model.map { .modelNotFound($0) } ?? .badRequest(message)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...: return .server(status: status, message: message)
        default:
            if error.type == "billing_error" { return .quotaExceeded(message) }
            return .badRequest(message)
        }
    }

    // MARK: OpenAI

    private static func isQuotaCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code == "credit_balance_exhausted" || code == "insufficient_quota"
            || code.hasSuffix("spend_limit_exceeded") || code.hasSuffix("usage_limit_exceeded")
    }

    private static func openAI(
        _ status: Int, _ error: Parsed, _ message: String, _ retryAfter: TimeInterval?, _ model: String?
    ) -> ProviderError {
        if isQuotaCode(error.code) || isQuotaCode(error.type) { return .quotaExceeded(message) }
        switch status {
        case 401: return .invalidAPIKey
        case 403: return .permissionDenied(message)
        case 404:
            if let model { return .modelNotFound(model) }
            return .badRequest(message)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 503: return .overloaded
        case 500...: return .server(status: status, message: message)
        default: return .badRequest(message)
        }
    }

    // MARK: Parsing

    private struct Parsed {
        var message: String?
        var type: String?
        var code: String?
        var errorCode: String?
    }

    private static func parse(body: Data, style: Style) -> Parsed {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return Parsed() }
        var parsed = Parsed()
        parsed.message = error["message"] as? String
        parsed.type = error["type"] as? String
        parsed.code = error["code"] as? String
        if let details = error["details"] as? [String: Any] { parsed.errorCode = details["error_code"] as? String }
        return parsed
    }

    // MARK: Retry-After

    /// Seconds from a `Retry-After` header (delta-seconds or HTTP-date); header names are case-insensitive.
    public static func retryAfter(from headers: [String: String], now: Date = Date()) -> TimeInterval? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }
}

extension HTTPURLResponse {
    /// Header fields as plain strings.
    public var stringHeaders: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields { result["\(key)"] = "\(value)" }
        return result
    }
}
