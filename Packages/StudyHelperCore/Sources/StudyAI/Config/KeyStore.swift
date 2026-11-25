import Foundation
import Security

/// Storage for API keys, one per configuration id. Keys never go to UserDefaults, files or logs.
public protocol KeyStore: Sendable {
    func saveKey(_ key: String, for configurationID: UUID) throws
    func readKey(for configurationID: UUID) throws -> String?
    func deleteKey(for configurationID: UUID) throws
    /// Configuration ids that have a stored key (accounts that are not a UUID are ignored). For cleaning up keys of
    /// configurations that no longer exist.
    func storedConfigurationIDs() throws -> [UUID]
}

public struct KeyStoreError: Error, Equatable, Sendable {
    public var status: Int32
    public init(status: Int32) { self.status = status }
}

/// In-memory keys for tests and UI tests.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]

    public init(keys: [UUID: String] = [:]) { self.keys = keys }

    public func saveKey(_ key: String, for configurationID: UUID) throws {
        lock.withLock { keys[configurationID] = key }
    }

    public func readKey(for configurationID: UUID) throws -> String? {
        lock.withLock { keys[configurationID] }
    }

    public func deleteKey(for configurationID: UUID) throws {
        lock.withLock { _ = keys.removeValue(forKey: configurationID) }
    }

    public func storedConfigurationIDs() throws -> [UUID] {
        lock.withLock { Array(keys.keys) }
    }
}

/// Keychain (generic password), device-bound and only readable while unlocked.
public struct KeychainKeyStore: KeyStore {
    public static let defaultService = "MiloG.StudyHelper1.apikeys"

    public let service: String

    public init(service: String = KeychainKeyStore.defaultService) { self.service = service }

    // MARK: Query building (pure, tested without touching the Keychain)

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func addQuery(service: String, account: String, key: String) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return query
    }

    static func updateAttributes(key: String) -> [String: Any] {
        [kSecValueData as String: Data(key.utf8)]
    }

    static func readQuery(service: String, account: String) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// All items of the service with their attributes (account names), no secrets.
    static func listQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
    }

    // MARK: KeyStore

    public func saveKey(_ key: String, for configurationID: UUID) throws {
        let account = configurationID.uuidString
        let status = SecItemUpdate(
            Self.baseQuery(service: service, account: account) as CFDictionary,
            Self.updateAttributes(key: key) as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound:
            let added = SecItemAdd(Self.addQuery(service: service, account: account, key: key) as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeyStoreError(status: added) }
        default: throw KeyStoreError(status: status)
        }
    }

    public func readKey(for configurationID: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.readQuery(service: service, account: configurationID.uuidString) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteKey(for configurationID: UUID) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: configurationID.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError(status: status) }
    }

    public func storedConfigurationIDs() throws -> [UUID] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.listQuery(service: service) as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap { UUID(uuidString: $0) } }
    }
}
