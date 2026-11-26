import StudyAI
import StudyData
import SwiftUI

// German display names for the AI enums.

extension ReasoningLevel {
    var germanName: String {
        switch self {
        case .off: "Aus"
        case .minimal: "Minimal"
        case .low: "Niedrig"
        case .medium: "Mittel"
        case .high: "Hoch"
        case .xhigh: "Sehr hoch"
        case .max: "Maximal"
        }
    }
}

extension AITask {
    var germanName: String {
        switch self {
        case .digitization: "Digitalisierung"
        case .structuring: "Strukturierung"
        case .query: "Abfragen"
        case .freeTextGrading: "Freitext bewerten"
        case .flashcards: "Karteikarten"
        case .chat: "Chat"
        case .tips: "Tipps"
        case .connectionTest: "Verbindungstest"
        case .wordSuggestions: "Wortvorschläge"
        }
    }

    /// Tasks with their own reasoning setting in the settings (no digitization, no connection test).
    static let reasoningTasks: [AITask] = [.structuring, .query, .freeTextGrading, .flashcards, .chat, .tips]
}

extension ProviderKind {
    var germanName: String {
        switch self {
        case .mock: "Test (Mock)"
        case .claude: "Claude-API"
        case .openAI: "OpenAI-API"
        case .openAICompatible: "Selbst gehostet (OpenAI-kompatibel)"
        case .appleFoundation: "Apple On-Device"
        }
    }

    /// Kinds the user can add, in picker order.
    static let selectable: [ProviderKind] = [.claude, .openAI, .openAICompatible, .appleFoundation]

    /// Default name of a new configuration.
    var defaultName: String {
        switch self {
        case .mock: "Test"
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .openAICompatible: "Selbst gehostet"
        case .appleFoundation: "Apple On-Device"
        }
    }

    var needsKey: Bool { self == .claude || self == .openAI }
    var allowsKey: Bool { self != .appleFoundation && self != .mock }
}

extension ProviderConfiguration {
    /// Whether the image support of the model is unknown, so the user decides ("Modell kann Bilder verarbeiten").
    /// Only self-hosted servers that did not report capabilities (not Ollama) are unknown.
    var imageSupportIsUnknown: Bool {
        guard kind == .openAICompatible else { return false }
        return cachedCapabilities == nil || cachedCapabilities == ProviderCapabilities(supportsStreaming: true)
    }
}

/// Number and cost formatting for the request log.
enum LogFormat {
    static func tokens(_ value: Int?) -> String { value.map { $0.formatted() } ?? "–" }

    static func amount(_ value: Double, symbol: String) -> String {
        let digits = value == 0 ? 2 : (abs(value) < 0.01 ? 5 : 4)
        let number = value.formatted(.number.precision(.fractionLength(2...digits)))
        return "\(number) \(symbol)"
    }

    /// "0,0123 € · 0,0143 $ (geschätzt)", "kostenlos" or "unbekannt".
    static func cost(known: Bool, eur: Double?, usd: Double?, free: Bool) -> String {
        guard known, let eur, let usd else { return "unbekannt" }
        if free { return "kostenlos" }
        return "\(amount(eur, symbol: "€")) · \(amount(usd, symbol: "$")) (geschätzt)"
    }

    static func cost(of log: RequestLog) -> String {
        cost(
            known: log.costKnown, eur: log.costEUR, usd: log.costUSD,
            free: ProviderKind(rawValue: log.providerKind)?.isFree ?? false)
    }

    static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) s"
    }
}
