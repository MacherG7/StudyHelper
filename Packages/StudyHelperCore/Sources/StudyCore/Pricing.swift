import Foundation

/// Price of a model in USD per 1 million tokens. Prices change; every value derived from them is an *estimate*
/// (source: docs/API-REFERENZ.md, can be overridden by the user).
public struct ModelPrice: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// From this many prompt tokens on (strictly more), `longInput`/`longOutput` apply to the whole request.
    public var longPromptThreshold: Int?
    public var longInput: Double?
    public var longOutput: Double?

    public init(
        input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
        longPromptThreshold: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite = cacheWrite ?? input * 1.25
        self.longPromptThreshold = longPromptThreshold
        self.longInput = longInput
        self.longOutput = longOutput
    }
}

public struct PriceTable: Sendable, Equatable {
    /// User overrides win over the defaults.
    public var overrides: [String: ModelPrice]

    public init(overrides: [String: ModelPrice] = [:]) { self.overrides = overrides }

    private static func claude(_ input: Double, _ output: Double, read: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: read)
    }

    private static func openAI(_ input: Double, _ cached: Double, _ output: Double) -> ModelPrice {
        // OpenAI does not bill cache writes separately.
        ModelPrice(input: input, output: output, cacheRead: cached, cacheWrite: input)
    }

    public static let defaults: [String: ModelPrice] = [
        // Claude
        "claude-opus-5-5": claude(4, 20, read: 0.20),
        "claude-sonnet-5-5": claude(2, 10, read: 0.10),
        "claude-haiku-5-5": ModelPrice(
            input: 0.10, output: 0.50, longPromptThreshold: 100_000, longInput: 0.50, longOutput: 2.50),
        "claude-fable-5-2": claude(8, 40, read: 0.20),
        "claude-opus-5": claude(5, 25),
        "claude-sonnet-5": claude(2, 10),
        "claude-opus-4-8": claude(5, 25),
        "claude-opus-4-7": claude(5, 25),
        "claude-opus-4-6": claude(5, 25),
        "claude-sonnet-4-6": claude(3, 15),
        "claude-haiku-4-5": claude(1, 5),
        // OpenAI
        "gpt-6.2-astra": openAI(8, 0.40, 40),
        "gpt-6.2-sol": openAI(2, 0.10, 10),
        "gpt-6-astra": openAI(10, 1.00, 50),
        "gpt-6.1-sol": openAI(2, 0.10, 10),
        "gpt-6.1-terra": openAI(1, 0.05, 5),
        "gpt-6-luna": openAI(0.10, 0.01, 0.50),
        "gpt-6-sol": openAI(2, 0.20, 10),
        "gpt-5.6-sol": openAI(4, 0.40, 20),
        "gpt-5.6-terra": openAI(2, 0.20, 12),
        "gpt-5.6-luna": openAI(0.20, 0.02, 1.20),
        "gpt-5.5": openAI(5, 0.50, 30),
        "gpt-5.4": openAI(2.50, 0.25, 15),
        "gpt-5.4-mini": openAI(0.75, 0.075, 4.50),
        "gpt-5.4-nano": openAI(0.20, 0.02, 1.25),
        "gpt-5.2": openAI(1.75, 0.175, 14),
        "gpt-5.1": openAI(1.25, 0.125, 10),
        "gpt-5": openAI(1.25, 0.125, 10),
        "gpt-5-mini": openAI(0.25, 0.025, 2),
        "gpt-5-nano": openAI(0.05, 0.005, 0.40),
    ]

    /// Override, then exact id, then the longest default id followed by "-" (dated variants such as
    /// `claude-sonnet-5-5-20261001`). A prefix match that continues with a letter/digit is not a match.
    public func price(for model: String) -> ModelPrice? {
        if let override = overrides[model] { return override }
        if let exact = Self.defaults[model] { return exact }
        if let key = overrides.keys.filter({ model.hasPrefix($0 + "-") }).max(by: { $0.count < $1.count }) {
            return overrides[key]
        }
        let key = Self.defaults.keys.filter { model.hasPrefix($0 + "-") }.max { $0.count < $1.count }
        return key.flatMap { Self.defaults[$0] }
    }
}

/// Estimated cost of one request. Always an estimate: prices and token counts come from the provider's usage data
/// and a price table that may be outdated.
public enum CostEstimate: Sendable, Hashable {
    case free
    case unknown
    case estimated(usd: Double, eur: Double)

    public var usd: Double? {
        switch self {
        case .free: return 0
        case .unknown: return nil
        case .estimated(let usd, _): return usd
        }
    }

    public var eur: Double? {
        switch self {
        case .free: return 0
        case .unknown: return nil
        case .estimated(_, let eur): return eur
        }
    }

    /// - Parameters:
    ///   - cacheIncludedInInput: OpenAI: `input` contains the cached tokens (billed at the cache price instead).
    ///     Claude: `input` excludes cache tokens.
    ///   - reasoningIncludedInOutput: reasoning tokens are already part of `output` (OpenAI and Claude); only when
    ///     false they are billed on top as output.
    public static func compute(
        model: String, table: PriceTable = PriceTable(), isFree: Bool = false, usdToEurRate: Double,
        input: Int?, output: Int?, cacheRead: Int? = nil, cacheWrite: Int? = nil, reasoning: Int? = nil,
        reasoningIncludedInOutput: Bool = true, cacheIncludedInInput: Bool
    ) -> CostEstimate {
        if isFree { return .free }
        guard let price = table.price(for: model), input != nil || output != nil else { return .unknown }
        let read = cacheRead ?? 0
        let write = cacheWrite ?? 0
        let rawInput = input ?? 0
        let freshInput = cacheIncludedInInput ? max(0, rawInput - read) : rawInput
        let promptTokens = cacheIncludedInInput ? rawInput : rawInput + read + write
        var inputPrice = price.input
        var outputPrice = price.output
        if let threshold = price.longPromptThreshold, promptTokens > threshold {
            inputPrice = price.longInput ?? inputPrice
            outputPrice = price.longOutput ?? outputPrice
        }
        let billedOutput = (output ?? 0) + (reasoningIncludedInOutput ? 0 : (reasoning ?? 0))
        let usd = (Double(freshInput) * inputPrice + Double(read) * price.cacheRead
            + Double(write) * price.cacheWrite + Double(billedOutput) * outputPrice) / 1_000_000
        return .estimated(usd: usd, eur: usd * usdToEurRate)
    }
}
