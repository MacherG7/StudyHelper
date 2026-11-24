import Foundation
import StudyCore

/// Everything the user can set for the AI layer, stored as one JSON value (no secrets).
public struct AISettings: Codable, Sendable, Equatable {
    public var configurations: [ProviderConfiguration]
    public var defaultProviderID: UUID?
    /// Provider for digitization; nil = the default provider.
    public var digitizationProviderID: UUID?
    public var reasoningOverrides: [AITask: ReasoningLevel]
    public var developerModeEnabled: Bool
    public var usdToEurRate: Double
    /// Prices the user entered (model id -> price); they win over the built-in table.
    public var priceOverrides: [String: ModelPrice]

    public static let defaultUSDToEURRate = 0.86

    public init(
        configurations: [ProviderConfiguration] = [], defaultProviderID: UUID? = nil,
        digitizationProviderID: UUID? = nil, reasoningOverrides: [AITask: ReasoningLevel] = [:],
        developerModeEnabled: Bool = false, usdToEurRate: Double = AISettings.defaultUSDToEURRate,
        priceOverrides: [String: ModelPrice] = [:]
    ) {
        self.configurations = configurations
        self.defaultProviderID = defaultProviderID
        self.digitizationProviderID = digitizationProviderID
        self.reasoningOverrides = reasoningOverrides
        self.developerModeEnabled = developerModeEnabled
        self.usdToEurRate = usdToEurRate
        self.priceOverrides = priceOverrides
    }

    // Every field is optional on read, so settings written by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configurations = try c.decodeIfPresent([ProviderConfiguration].self, forKey: .configurations) ?? []
        defaultProviderID = try c.decodeIfPresent(UUID.self, forKey: .defaultProviderID)
        digitizationProviderID = try c.decodeIfPresent(UUID.self, forKey: .digitizationProviderID)
        reasoningOverrides = try c.decodeIfPresent([AITask: ReasoningLevel].self, forKey: .reasoningOverrides) ?? [:]
        developerModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled) ?? false
        usdToEurRate = try c.decodeIfPresent(Double.self, forKey: .usdToEurRate) ?? Self.defaultUSDToEURRate
        priceOverrides = try c.decodeIfPresent([String: ModelPrice].self, forKey: .priceOverrides) ?? [:]
    }

    public var priceTable: PriceTable { PriceTable(overrides: priceOverrides) }

    public func configuration(id: UUID?) -> ProviderConfiguration? {
        guard let id else { return nil }
        return configurations.first { $0.id == id }
    }

    public var defaultConfiguration: ProviderConfiguration? { configuration(id: defaultProviderID) ?? configurations.first }

    public var digitizationConfiguration: ProviderConfiguration? {
        configuration(id: digitizationProviderID) ?? defaultConfiguration
    }
}

/// `AISettings` in UserDefaults. A corrupt value never crashes: reads fall back to defaults, and the raw data stays
/// untouched until the next `save`.
public final class AISettingsStore: @unchecked Sendable {
    public static let defaultsKey = "StudyHelper.ai.settings.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Pass a dedicated suite in tests.
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True when stored data exists but cannot be read (the defaults are in use).
    public var isStoredDataCorrupt: Bool {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.defaultsKey) else { return false }
            return (try? JSONDecoder().decode(AISettings.self, from: data)) == nil
        }
    }

    public func load() -> AISettings {
        lock.withLock { loadLocked() }
    }

    public func save(_ settings: AISettings) {
        lock.withLock { saveLocked(settings) }
    }

    /// Reads, changes and writes under one lock.
    @discardableResult
    public func update(_ change: (inout AISettings) -> Void) -> AISettings {
        lock.withLock {
            var settings = loadLocked()
            change(&settings)
            saveLocked(settings)
            return settings
        }
    }

    private func loadLocked() -> AISettings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else { return AISettings() }
        return settings
    }

    private func saveLocked(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
