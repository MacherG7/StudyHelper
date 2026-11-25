import Foundation
import Testing

@testable import StudyAI

@Suite("Seiteninhalt je nach Fähigkeit des Modells: PDF oder Bild plus Text")
struct PageContentTests {
    private let capabilities = ProviderCapabilities(supportsImages: true, supportsTools: true, reasoningLevels: [.low])
    private let noImages = ProviderCapabilities(supportsImages: false, supportsTools: true, reasoningLevels: [.low])
    private let pdf = DocumentPayload(data: TestSupport.pdfBytes, filename: "seite-1.pdf")
    private let image = ImagePayload(data: TestSupport.pngBytes, mediaType: "image/png")
    private let text = "Chlorophyll ist grün."

    private func claude(_ capabilities: ProviderCapabilities) -> ClaudeProvider {
        let configuration = TestSupport.configuration(.claude, model: "claude-sonnet-5-5", capabilities: capabilities)
        return ClaudeProvider(
            configuration: configuration, keyStore: TestSupport.keyStore(for: configuration), transport: StubTransport(),
            retry: TestSupport.fastRetry)
    }

    private func openAI(_ capabilities: ProviderCapabilities) -> OpenAIProvider {
        let configuration = TestSupport.configuration(.openAI, model: "gpt-5.5", capabilities: capabilities)
        return OpenAIProvider(
            configuration: configuration, keyStore: TestSupport.keyStore(for: configuration), transport: StubTransport(),
            retry: TestSupport.fastRetry)
    }

    private func compatible(_ capabilities: ProviderCapabilities) -> OpenAICompatibleProvider {
        let configuration = TestSupport.configuration(
            .openAICompatible, model: "qwen3-vl", baseURL: "http://192.168.1.2:11434", capabilities: capabilities)
        return OpenAICompatibleProvider(
            configuration: configuration, keyStore: InMemoryKeyStore(), transport: StubTransport(),
            retry: TestSupport.fastRetry)
    }

    private func parts(_ provider: some ModelProvider) -> [MessageContent] {
        PageContent.parts(for: provider, pdf: pdf, image: image, text: text)
    }

    @Test("PDF-fähig sind Claude, OpenAI und der Mock mit Bildunterstützung")
    func documentCapability() {
        #expect(claude(capabilities).supportsDocuments)
        #expect(openAI(capabilities).supportsDocuments)
        #expect(MockProvider(capabilities: capabilities).supportsDocuments)
        #expect(!claude(noImages).supportsDocuments)
        #expect(!openAI(noImages).supportsDocuments)
        #expect(!MockProvider(capabilities: noImages).supportsDocuments)
    }

    @Test("OpenAI-kompatible Server nehmen nie PDFs, auch nicht mit Bildunterstützung")
    func compatibleNeverDocuments() {
        #expect(!compatible(capabilities).supportsDocuments)
        #expect(!compatible(noImages).supportsDocuments)
    }

    #if canImport(FoundationModels)
    @Test("Das Apple-Modell nimmt keine PDFs")
    func appleNeverDocuments() {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let provider = AppleFoundationProvider(configuration: TestSupport.configuration(.appleFoundation, model: "apple-foundation"))
        #expect(!provider.supportsDocuments)
        #expect(PageContent.parts(for: provider, pdf: pdf, image: image, text: text) == [.text(text)])
    }
    #endif

    @Test("Mit PDF-Unterstützung geht die Seite als PDF")
    func pdfWhereSupported() {
        #expect(parts(claude(capabilities)) == [.document(pdf)])
        #expect(parts(openAI(capabilities)) == [.document(pdf)])
        #expect(parts(MockProvider(capabilities: capabilities)) == [.document(pdf)])
    }

    @Test("Ohne PDF-Unterstützung gehen Bild und gespeicherter Text")
    func imageAndTextOtherwise() {
        #expect(parts(compatible(capabilities)) == [.image(image), .text(text)])
    }

    @Test("Ohne Bildunterstützung geht nur der gespeicherte Text")
    func textOnlyWithoutImages() {
        #expect(parts(claude(noImages)) == [.text(text)])
        #expect(parts(compatible(noImages)) == [.text(text)])
        #expect(parts(MockProvider(capabilities: noImages)) == [.text(text)])
    }

    @Test("Fehlt das PDF, gehen Bild und Text; leerer Text entfällt")
    func missingPieces() {
        let provider = MockProvider(capabilities: capabilities)
        #expect(PageContent.parts(for: provider, pdf: nil, image: image, text: text) == [.image(image), .text(text)])
        #expect(PageContent.parts(for: provider, pdf: nil, image: image, text: "  \n") == [.image(image)])
        #expect(PageContent.parts(for: provider, pdf: nil, image: nil, text: nil).isEmpty)
    }

    @Test("Der Mock nimmt beide Formen an; im Log stehen nur Platzhalter")
    func mockAcceptsBothAndLogsPlaceholders() async throws {
        let withPDF = MockProvider(capabilities: capabilities)
        let request = TestSupport.request([ChatMessage(role: .user, content: [.text("Fasse zusammen.")] + parts(withPDF))])
        let response = try await withPDF.respond(to: request)
        #expect(response.metadata.sentContent == [.text, .document])
        #expect(response.metadata.rawRequest.contains("<PDF, \(pdf.data.count) Bytes>"))
        #expect(!response.metadata.rawRequest.contains(pdf.data.base64EncodedString()))

        let fallback = MockProvider(capabilities: ProviderCapabilities(supportsImages: true, supportsTools: true))
        // Same capabilities but a provider kind without PDF support: image plus text.
        let content = PageContent.parts(
            pdf: pdf, image: image, text: text, supportsDocuments: false, supportsImages: fallback.capabilities.supportsImages)
        let second = try await fallback.respond(
            to: TestSupport.request([ChatMessage(role: .user, content: [.text("Fasse zusammen.")] + content)]))
        #expect(second.metadata.sentContent == [.text, .image])
        #expect(second.metadata.rawRequest.contains("<Bild, \(image.data.count) Bytes>"))
        #expect(!second.metadata.rawRequest.contains(image.data.base64EncodedString()))
    }
}
