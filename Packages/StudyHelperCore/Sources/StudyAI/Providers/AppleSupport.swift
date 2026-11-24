import Foundation

/// Whether the on-device Apple model can be used. Plain enum so the app can show a reason without importing
/// FoundationModels (which does not exist on older systems).
public enum AppleModelAvailability: String, Sendable, Hashable, CaseIterable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    /// iOS/macOS older than 26 or no FoundationModels framework.
    case unsupportedOS

    public var isAvailable: Bool { self == .available }

    /// Short explanation for the settings screen.
    public var germanDescription: String {
        switch self {
        case .available: return "Das Apple-Modell auf dem Gerät ist bereit."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence ist ausgeschaltet. Du kannst es in den Einstellungen unter „Apple Intelligence & Siri“ einschalten."
        case .deviceNotEligible: return "Dieses Gerät unterstützt Apple Intelligence nicht."
        case .modelNotReady:
            return "Das Apple-Modell wird noch geladen oder vorbereitet. Bitte später noch einmal versuchen."
        case .unsupportedOS: return "Das Apple-Modell braucht iOS 26 oder neuer."
        }
    }

    /// Current state on this device (`unsupportedOS` where the framework or OS is missing).
    public static var current: AppleModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { return AppleFoundationProvider.availabilityStatus }
        #endif
        return .unsupportedOS
    }
}

/// Pure helpers of the Apple provider (testable without the model).
public enum AppleFoundationText {
    /// Streaming snapshots contain the whole text so far; this is the part not yet delivered. If the model rewrote
    /// earlier text (snapshot is not an extension), only characters beyond the delivered length are returned.
    public static func newSuffix(previous: String, current: String) -> String {
        if current.hasPrefix(previous) { return String(current.dropFirst(previous.count)) }
        return current.count > previous.count ? String(current.dropFirst(previous.count)) : ""
    }

    /// The conversation as one prompt: a single user message as is, otherwise a labelled transcript ending with the
    /// last user message. Images and tool parts are skipped (not supported by this provider).
    public static func prompt(from messages: [ChatMessage]) -> String {
        func text(of message: ChatMessage) -> String {
            message.content.compactMap { part -> String? in
                if case .text(let text) = part, !text.isEmpty { return text }
                return nil
            }.joined(separator: "\n\n")
        }
        let turns = messages.map { ($0.role, text(of: $0)) }.filter { !$0.1.isEmpty }
        if turns.count == 1 { return turns[0].1 }
        return turns.map { ($0.0 == .user ? "Nutzer: " : "Assistent: ") + $0.1 }.joined(separator: "\n\n")
    }
}
