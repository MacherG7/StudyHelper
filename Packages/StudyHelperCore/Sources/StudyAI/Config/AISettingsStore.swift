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

    /// Decoding is lenient: every field is optional (settings of an older version still load), and single entries
    /// that cannot be read (e.g. an unknown provider kind or reasoning level written by a newer version) are skipped
    /// instead of failing the whole blob. Skipped entries are counted in `decoder.userInfo[.unreadableCounter]`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let counter = decoder.userInfo[.unreadableCounter] as? UnreadableCounter
        func skipped(_ count: Int = 1) { counter?.add(count) }

        configurations = []
        if c.contains(.configurations) {
            if var list = try? c.nestedUnkeyedContainer(forKey: .configurations) {
                while !list.isAtEnd {
                    if let entry = try? list.decode(Lossy<ProviderConfiguration>.self), let value = entry.value {
                        configurations.append(value)
                    } else {
                        skipped()
                    }
                }
            } else {
                skipped()
            }
        }
        defaultProviderID = try? c.decodeIfPresent(UUID.self, forKey: .defaultProviderID)
        digitizationProviderID = try? c.decodeIfPresent(UUID.self, forKey: .digitizationProviderID)
        reasoningOverrides = [:]
        if c.contains(.reasoningOverrides) {
            // `[AITask: ReasoningLevel]` is stored as a flat array [key, value, key, value, ...].
            if let flat = try? c.decode([JSONValue].self, forKey: .reasoningOverrides) {
                var index = 0
                while index + 1 < flat.count {
                    if case .string(let task) = flat[index], case .string(let level) = flat[index + 1],
                       let task = AITask(rawValue: task), let level = ReasoningLevel(rawValue: level) {
                        reasoningOverrides[task] = level
                    } else {
                        skipped()
                    }
                    index += 2
                }
                if flat.count % 2 == 1 { skipped() }
            } else if let object = try? c.decode([String: JSONValue].self, forKey: .reasoningOverrides) {
                for (task, level) in object {
                    if case .string(let level) = level, let task = AITask(rawValue: task),
                       let level = ReasoningLevel(rawValue: level) {
                        reasoningOverrides[task] = level
                    } else {
                        skipped()
                    }
                }
            } else {
                skipped()
            }
        }
        developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? false
        usdToEurRate = (try? c.decodeIfPresent(Double.self, forKey: .usdToEurRate)) ?? Self.defaultUSDToEURRate
        priceOverrides = (try? c.decodeIfPresent([String: ModelPrice].self, forKey: .priceOverrides)) ?? [:]
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

/// Counts entries skipped while decoding (see `AISettings.init(from:)`).
final class UnreadableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add(_ amount: Int) { lock.withLock { value += amount } }
}

extension CodingUserInfoKey {
    static let unreadableCounter = CodingUserInfoKey(rawValue: "StudyAI.unreadableCounter")!
}

/// Decodes a value without ever throwing: nil if it cannot be read.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// `AISettings` in UserDefaults. A corrupt value never crashes and unreadable entries never disappear silently:
/// - entries that cannot be read (unknown values of a newer version) are skipped, the rest loads;
/// - as soon as anything was unreadable, the raw data is copied to a backup key (`backupKey`, one older copy in
///   `previousBackupKey`) before any write can replace it, and the backup stays until `discardBackup()`;
/// - `hasUnreadableEntries` stays true while such a backup exists.
public final class AISettingsStore: @unchecked Sendable {
    public static let defaultsKey = "StudyHelper.ai.settings.v1"
    public static let backupKey = "StudyHelper.ai.settings.v1.backup"
    public static let previousBackupKey = "StudyHelper.ai.settings.v1.backup.previous"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Pass a dedicated suite in tests.
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private struct Reading {
        var settings: AISettings
        /// Number of skipped entries; nil = the whole value is unreadable.
        var unreadable: Int?
        var hasData: Bool
        var isClean: Bool { unreadable == 0 }
    }

    private func readLocked() -> Reading {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return Reading(settings: AISettings(), unreadable: 0, hasData: false)
        }
        let counter = UnreadableCounter()
        let decoder = JSONDecoder()
        decoder.userInfo[.unreadableCounter] = counter
        guard let settings = try? decoder.decode(AISettings.self, from: data) else {
            return Reading(settings: AISettings(), unreadable: nil, hasData: true)
        }
        return Reading(settings: settings, unreadable: counter.count, hasData: true)
    }

    /// Copies the stored raw data to the backup key if anything in it is unreadable.
    private func backUpIfNeededLocked(_ reading: Reading) {
        guard reading.hasData, !reading.isClean, let raw = defaults.data(forKey: Self.defaultsKey) else { return }
        let existing = defaults.data(forKey: Self.backupKey)
        guard existing != raw else { return }
        if let existing { defaults.set(existing, forKey: Self.previousBackupKey) }
        defaults.set(raw, forKey: Self.backupKey)
    }

    /// True when stored data exists but cannot be read at all (the defaults are in use).
    public var isStoredDataCorrupt: Bool {
        lock.withLock { readLocked().unreadable == nil }
    }

    /// True when the stored data had entries that could not be read, or a backup of such data still exists. While
    /// this is true, nothing may be deleted that the skipped entries might need (e.g. Keychain keys).
    public var hasUnreadableEntries: Bool {
        lock.withLock {
            let reading = readLocked()
            return !reading.isClean || defaults.data(forKey: Self.backupKey) != nil
        }
    }

    /// The raw data that could not be (fully) read, if kept.
    public var backupData: Data? { lock.withLock { defaults.data(forKey: Self.backupKey) } }

    /// Deletes the backups (the user acknowledged the loss).
    public func discardBackup() {
        lock.withLock {
            defaults.removeObject(forKey: Self.backupKey)
            defaults.removeObject(forKey: Self.previousBackupKey)
        }
    }

    public func load() -> AISettings {
        lock.withLock {
            let reading = readLocked()
            backUpIfNeededLocked(reading)
            return reading.settings
        }
    }

    public func save(_ settings: AISettings) {
        lock.withLock { saveLocked(settings) }
    }

    /// Reads, changes and writes under one lock.
    @discardableResult
    public func update(_ change: (inout AISettings) -> Void) -> AISettings {
        lock.withLock {
            var settings = readLocked().settings
            change(&settings)
            saveLocked(settings)
            return settings
        }
    }

    private func saveLocked(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        backUpIfNeededLocked(readLocked())  // never overwrite unreadable data without a copy
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
