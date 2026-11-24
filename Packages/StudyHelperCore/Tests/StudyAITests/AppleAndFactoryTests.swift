import Foundation
import Testing

@testable import StudyAI

#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite("Apple: Verfügbarkeit und Text")
struct AppleSupportTests {
    @Test("Alle Verfügbarkeitszustände haben eine deutsche Beschreibung; nur available ist nutzbar")
    func descriptions() {
        for state in AppleModelAvailability.allCases {
            #expect(!state.germanDescription.isEmpty)
            #expect(state.isAvailable == (state == .available))
        }
        #expect(AppleModelAvailability.unsupportedOS.germanDescription.contains("iOS 26"))
        #expect(AppleModelAvailability.appleIntelligenceNotEnabled.germanDescription.contains("Apple Intelligence"))
    }

    #if canImport(FoundationModels)
    @Test("Abbildung der System-Verfügbarkeit auf AppleModelAvailability")
    func mapping() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        #expect(AppleFoundationProvider.map(.available) == .available)
        #expect(AppleFoundationProvider.map(.unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceNotEnabled)
        #expect(AppleFoundationProvider.map(.unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(AppleFoundationProvider.map(.unavailable(.modelNotReady)) == .modelNotReady)
    }

    @Test("Apple-Anbieter: keine Bilder, keine Werkzeuge, kein Reasoning")
    func capabilities() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let provider = AppleFoundationProvider(configuration: TestSupport.configuration(.appleFoundation, model: "apple-foundation"))
        #expect(!provider.capabilities.supportsImages)
        #expect(!provider.capabilities.supportsTools)
        #expect(provider.capabilities.reasoningLevels.isEmpty)
        #expect(provider.kind == .appleFoundation)
    }
    #endif

    @Test("Snapshot-Differenz: nur der neue Textteil wird geliefert")
    func delta() {
        #expect(AppleFoundationText.newSuffix(previous: "", current: "Hal") == "Hal")
        #expect(AppleFoundationText.newSuffix(previous: "Hal", current: "Hallo Welt") == "lo Welt")
        #expect(AppleFoundationText.newSuffix(previous: "Hallo", current: "Hallo") == "")
        #expect(AppleFoundationText.newSuffix(previous: "Grü", current: "Grüße ☀️") == "ße ☀️")
    }

    @Test("Snapshot-Differenz: umgeschriebener Text liefert nie doppelten oder negativen Text")
    func deltaRewritten() {
        #expect(AppleFoundationText.newSuffix(previous: "Hallo Welt", current: "Hi") == "")
        #expect(AppleFoundationText.newSuffix(previous: "Hallo", current: "Hexxo Welt") == " Welt")
    }

    @Test("Prompt: einzelne Nutzernachricht unverändert, sonst beschrifteter Verlauf ohne Bilder")
    func prompt() {
        #expect(AppleFoundationText.prompt(from: [.user("Frage")]) == "Frage")
        let messages: [ChatMessage] = [
            .user("Hallo"), .assistant("Hi"),
            ChatMessage(role: .user, content: [.text("Und?"), .image(ImagePayload(data: Data([1]), mediaType: "image/png"))]),
        ]
        #expect(AppleFoundationText.prompt(from: messages) == "Nutzer: Hallo\n\nAssistent: Hi\n\nNutzer: Und?")
        #expect(AppleFoundationText.prompt(from: []) == "")
    }
}

@Suite("Anbieter-Fabrik")
struct ProviderFactoryTests {
    private func factory(_ stub: StubTransport = StubTransport()) -> ProviderFactory {
        ProviderFactory(keyStore: InMemoryKeyStore(), transport: stub, retry: TestSupport.fastRetry)
    }

    @Test("Jede Art liefert den passenden Anbieter und Katalog")
    func kinds() throws {
        let factory = factory()
        #expect(try factory.makeProvider(for: TestSupport.configuration(.claude)) is ClaudeProvider)
        #expect(try factory.makeProvider(for: TestSupport.configuration(.openAI)) is OpenAIProvider)
        #expect(try factory.makeProvider(for: TestSupport.configuration(.openAICompatible, baseURL: "http://localhost:11434")) is OpenAICompatibleProvider)
        #expect(try factory.makeProvider(for: TestSupport.configuration(.mock)) is MockProvider)
        #expect(try factory.makeCatalog(for: TestSupport.configuration(.claude)) is ClaudeProvider)
        #expect(try factory.makeCatalog(for: TestSupport.configuration(.openAI)) is OpenAIProvider)
        #expect(try factory.makeCatalog(for: TestSupport.configuration(.openAICompatible, baseURL: "https://example.org")) is OpenAICompatibleProvider)
        #expect(try factory.makeCatalog(for: TestSupport.configuration(.mock)) is StaticModelCatalog)
        #expect(try factory.makeCatalog(for: TestSupport.configuration(.appleFoundation)) is StaticModelCatalog)
    }

    @Test("OpenAI-kompatibel ohne gültige Adresse wird abgelehnt")
    func invalidBase() {
        #expect(throws: ProviderError.self) {
            _ = try factory().makeProvider(for: TestSupport.configuration(.openAICompatible, baseURL: "kaputt"))
        }
    }

    @Test("Fähigkeiten: zwischengespeicherte mit Bild-Einstellung; Mock mit Standard")
    func capabilities() throws {
        let cached = ProviderCapabilities(supportsImages: false, supportsTools: true, reasoningLevels: [.low])
        let configuration = TestSupport.configuration(.claude, capabilities: cached, imageOverride: true)
        let result = ProviderFactory.capabilities(of: configuration)
        #expect(result.supportsImages)
        #expect(result.reasoningLevels == [.low])
        #expect(try factory().makeProvider(for: TestSupport.configuration(.mock)).capabilities.supportsImages)
    }

    @Test("Mock-Anbieter aus der Fabrik antwortet mit dem Standardskript")
    func mockAnswers() async throws {
        let provider = try factory().makeProvider(for: TestSupport.configuration(.mock))
        let response = try await provider.respond(to: TestSupport.request())
        #expect(response.text == MockScript().answer)
    }

    @Test("Claude aus der Fabrik: Anfrage geht über den übergebenen Transport")
    func usesGivenTransport() async throws {
        let stub = StubTransport([.init(lines: TestSupport.sse([(nil, #"{"type":"message_stop"}"#)]))])
        let configuration = TestSupport.configuration(.claude, capabilities: ProviderCapabilities())
        let keys = TestSupport.keyStore(for: configuration)
        let provider = try ProviderFactory(keyStore: keys, transport: stub, retry: TestSupport.fastRetry).makeProvider(for: configuration)
        _ = try await provider.respond(to: TestSupport.request())
        #expect(stub.requests.count == 1)
    }
}

@Suite("Keine echten Netzwerkzugriffe")
struct NoNetworkGuardTests {
    @Test("Kein Test erzeugt eine URLSessionTransport-Instanz oder ruft URLSession direkt auf")
    func noRealTransportInTests() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 8)
        // Search terms are assembled so that this file does not match itself.
        let forbidden = ["URLSessionTransport" + "(", "URLSession" + ".shared", "URLSession" + "(configuration"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for term in forbidden {
                #expect(!text.contains(term), "\(file.lastPathComponent) enthält \(term)")
            }
        }
        // The provider test files all build on the stub.
        for name in ["ClaudeProviderTests", "OpenAIProviderTests", "OpenAICompatibleProviderTests"] {
            let text = try String(contentsOf: directory.appendingPathComponent("\(name).swift"), encoding: .utf8)
            #expect(text.contains("StubTransport"), "\(name) braucht StubTransport")
        }
    }
}
