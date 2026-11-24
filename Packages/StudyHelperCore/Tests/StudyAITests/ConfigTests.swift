import Foundation
import Security
import Testing
import StudyCore

@testable import StudyAI

private func makeDefaults() -> (UserDefaults, String) {
    let suite = "StudyAITests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Suite("Einstellungen")
struct AISettingsStoreTests {
    @Test("Leerer Speicher liefert Standardwerte")
    func defaultsWhenEmpty() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults).load()
        #expect(settings.configurations.isEmpty)
        #expect(settings.usdToEurRate == 0.86)
        #expect(!settings.developerModeEnabled)
        #expect(settings.reasoningOverrides.isEmpty)
    }

    @Test("Alles überlebt Speichern und Laden")
    func roundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        let claude = ProviderConfiguration(
            name: "Claude privat", kind: .claude, model: "claude-sonnet-5-5", reasoning: .high,
            imageSupportOverride: true,
            cachedCapabilities: ProviderCapabilities(supportsImages: true, reasoningLevels: [.low, .high], contextSize: 1000))
        let local = ProviderConfiguration(
            name: "Ollama", kind: .openAICompatible, baseURL: "http://192.168.0.2:11434", model: "llama3")
        let settings = AISettings(
            configurations: [claude, local], defaultProviderID: claude.id, digitizationProviderID: local.id,
            reasoningOverrides: [.chat: .low, .digitization: .off], developerModeEnabled: true, usdToEurRate: 0.9,
            priceOverrides: ["x": ModelPrice(input: 1, output: 2)])
        store.save(settings)
        let loaded = AISettingsStore(defaults: defaults).load()
        #expect(loaded == settings)
        #expect(loaded.defaultConfiguration == claude)
        #expect(loaded.digitizationConfiguration == local)
        #expect(loaded.priceTable.price(for: "x")?.output == 2)
        #expect(claude.keychainAccount == claude.id.uuidString)
    }

    @Test("Update ändert atomar")
    func update() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        store.update { $0.developerModeEnabled = true }
        store.update { $0.usdToEurRate = 1 }
        let settings = store.load()
        #expect(settings.developerModeEnabled && settings.usdToEurRate == 1)
    }

    @Test("Beschädigte Daten führen zu Standardwerten und bleiben bis zum Überschreiben unangetastet")
    func corruptJSON() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let garbage = Data("{\"configurations\": [kaputt".utf8)
        defaults.set(garbage, forKey: AISettingsStore.defaultsKey)
        let store = AISettingsStore(defaults: defaults)
        #expect(store.isStoredDataCorrupt)
        #expect(store.load() == AISettings())
        #expect(defaults.data(forKey: AISettingsStore.defaultsKey) == garbage)
        store.save(AISettings(developerModeEnabled: true))
        #expect(!store.isStoredDataCorrupt)
        #expect(store.load().developerModeEnabled)
    }

    @Test("Ältere Einstellungen mit fehlenden Feldern bleiben lesbar")
    func missingFields() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"developerModeEnabled":true}"#.utf8), forKey: AISettingsStore.defaultsKey)
        let settings = AISettingsStore(defaults: defaults).load()
        #expect(settings.developerModeEnabled)
        #expect(settings.usdToEurRate == 0.86)
    }

    @Test("Bildunterstützung: eigene Einstellung gewinnt über die Modellliste")
    func imageOverride() {
        var config = ProviderConfiguration(
            name: "x", kind: .openAICompatible, model: "m", cachedCapabilities: ProviderCapabilities(supportsImages: false))
        #expect(!config.effectiveCapabilities.supportsImages)
        config.imageSupportOverride = true
        #expect(config.effectiveCapabilities.supportsImages)
    }
}

@Suite("Schlüsselspeicher")
struct KeyStoreTests {
    @Test("InMemoryKeyStore: speichern, lesen, überschreiben, löschen")
    func inMemory() throws {
        let store = InMemoryKeyStore()
        let id = UUID()
        #expect(try store.readKey(for: id) == nil)
        try store.saveKey("a", for: id)
        try store.saveKey("b", for: id)
        #expect(try store.readKey(for: id) == "b")
        #expect(try store.readKey(for: UUID()) == nil)
        try store.deleteKey(for: id)
        #expect(try store.readKey(for: id) == nil)
        try store.deleteKey(for: id)
    }

    @Test("InMemoryKeyStore ist von mehreren Threads nutzbar")
    func concurrent() async throws {
        let store = InMemoryKeyStore()
        let ids = (0..<50).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? store.saveKey(id.uuidString, for: id) } }
        }
        for id in ids { #expect(try store.readKey(for: id) == id.uuidString) }
    }

    @Test("Keychain-Abfragen: Dienst, Konto, Zugriffsschutz")
    func keychainQueries() {
        let service = KeychainKeyStore.defaultService
        #expect(service == "MiloG.StudyHelper1.apikeys")
        let base = KeychainKeyStore.baseQuery(service: service, account: "abc")
        #expect(base[kSecClass as String] as! CFString == kSecClassGenericPassword)
        #expect(base[kSecAttrService as String] as? String == service)
        #expect(base[kSecAttrAccount as String] as? String == "abc")
        #expect(base.count == 3)

        let add = KeychainKeyStore.addQuery(service: service, account: "abc", key: "geheim")
        #expect(add[kSecValueData as String] as? Data == Data("geheim".utf8))
        #expect(add[kSecAttrAccessible as String] as! CFString == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

        let read = KeychainKeyStore.readQuery(service: service, account: "abc")
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecMatchLimit as String] as! CFString == kSecMatchLimitOne)
        #expect(read[kSecValueData as String] == nil)

        let update = KeychainKeyStore.updateAttributes(key: "neu")
        #expect(update.count == 1)
        #expect(update[kSecValueData as String] as? Data == Data("neu".utf8))
    }
}
