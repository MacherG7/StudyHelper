import Foundation

// Stand 2026-11-24, Quelle: docs/API-REFERENZ.md
//
// OpenAI's `GET /v1/models` reports no capabilities (no reasoning levels, no image support), so they come from this
// maintained table, matched by model-id prefix (longest prefix wins). Facts from the reference are marked FACT;
// everything else is an ASSUMPTION that must be checked against the current OpenAI docs before changing the table.
//
// FACT  GPT-6 Astra, GPT-6.2 Astra, GPT-6.2 Sol reject `reasoning.effort: none`.
// FACT  GPT-6.1 Sol supports neither `none` nor `minimal`.
// FACT  Default effort is `medium` for GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna and GPT-5.5.
// FACT  Effort values in general: none, minimal, low, medium, high, xhigh, max (each model only a subset).
// ASSUMPTION  The docs give no level list per model: every gpt-5*/gpt-6* entry offers low, medium, high
//             (plus `off` where `none` is not rejected, i.e. not for the models named above).
// ASSUMPTION  gpt-5*/gpt-6* accept images (`input_image`), function calling and json_schema output.
// ASSUMPTION  Model ids: gpt-6-astra, gpt-6.2-astra, gpt-6.2-sol, gpt-6.1-sol, gpt-6-sol, gpt-6-luna, gpt-5.5
//             (pricing table ids in StudyCore/Pricing.swift).

public enum OpenAIModelTable {
    struct Entry {
        var prefix: String
        var levels: [ReasoningLevel]
        var defaultLevel: ReasoningLevel?
        var supportsImages: Bool
    }

    private static let standard: [ReasoningLevel] = [.low, .medium, .high]

    /// Longest prefixes first is enforced in `entry(for:)`.
    static let entries: [Entry] = [
        // FACT: no "none" (so no .off), no "minimal".
        Entry(prefix: "gpt-6.1-sol", levels: standard, defaultLevel: .medium, supportsImages: true),
        Entry(prefix: "gpt-6.2-sol", levels: standard, defaultLevel: nil, supportsImages: true),
        Entry(prefix: "gpt-6.2-astra", levels: standard, defaultLevel: nil, supportsImages: true),
        Entry(prefix: "gpt-6-astra", levels: standard, defaultLevel: nil, supportsImages: true),
        // FACT for the default; ASSUMPTION that `none` is accepted.
        Entry(prefix: "gpt-6-sol", levels: [.off] + standard, defaultLevel: .medium, supportsImages: true),
        Entry(prefix: "gpt-6-luna", levels: [.off] + standard, defaultLevel: .medium, supportsImages: true),
        Entry(prefix: "gpt-5.5", levels: [.off] + standard, defaultLevel: .medium, supportsImages: true),
        // ASSUMPTION: generic families.
        Entry(prefix: "gpt-6", levels: standard, defaultLevel: nil, supportsImages: true),
        Entry(prefix: "gpt-5", levels: standard, defaultLevel: nil, supportsImages: true),
    ]

    /// Ids that are clearly not chat models (embeddings, speech, images, moderation, realtime/audio, legacy completion).
    static let nonChatPrefixes = [
        "text-embedding", "embedding", "tts-", "whisper", "dall-e", "gpt-image", "omni-moderation", "text-moderation",
        "davinci", "babbage", "sora", "gpt-realtime", "gpt-audio", "chatgpt-image",
    ]
    static let nonChatFragments = ["-tts", "-transcribe", "-realtime", "-audio", "-embedding", "-moderation"]

    public static func isChatModel(_ id: String) -> Bool {
        let id = id.lowercased()
        if nonChatPrefixes.contains(where: { id.hasPrefix($0) }) { return false }
        return !nonChatFragments.contains(where: { id.contains($0) })
    }

    static func entry(for id: String) -> Entry? {
        let id = id.lowercased()
        return entries.filter { id.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
    }

    /// Capabilities of a model id. Unknown chat models: no reasoning levels, no image support (the user's
    /// "Modell kann Bilder verarbeiten" setting decides).
    public static func capabilities(for id: String) -> ProviderCapabilities {
        guard let entry = entry(for: id) else {
            return ProviderCapabilities(supportsImages: false, supportsTools: true, supportsStreaming: true)
        }
        return ProviderCapabilities(
            supportsImages: entry.supportsImages, supportsTools: true, supportsStreaming: true,
            supportsStructuredOutput: true, reasoningLevels: entry.levels, defaultReasoning: entry.defaultLevel)
    }
}
