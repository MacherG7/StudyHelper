import Foundation

/// Builds the user-message content that shows one page of the Lernstoff to a model, depending on what the model can
/// process: the page as PDF where PDFs are supported, otherwise the page image plus the stored text, and only the
/// stored text if the model takes no images either. Nothing is dropped silently that the model could use.
public enum PageContent {
    /// - Parameters:
    ///   - pdf: the page as a PDF (with its invisible text layer), if one exists.
    ///   - image: the page as an image, if one exists.
    ///   - text: the stored text of the page; empty or whitespace-only text is left out.
    ///   - supportsDocuments: the model takes `.document` parts (`ModelProvider.supportsDocuments`).
    ///   - supportsImages: the model takes `.image` parts (`ProviderCapabilities.supportsImages`).
    public static func parts(
        pdf: DocumentPayload?, image: ImagePayload?, text: String?, supportsDocuments: Bool, supportsImages: Bool
    ) -> [MessageContent] {
        if supportsDocuments, let pdf { return [.document(pdf)] }
        var parts: [MessageContent] = []
        if supportsImages, let image { parts.append(.image(image)) }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(text)) }
        return parts
    }

    /// The same for a configured provider (its kind and the capabilities of the model).
    public static func parts(
        for provider: some ModelProvider, pdf: DocumentPayload?, image: ImagePayload?, text: String?
    ) -> [MessageContent] {
        parts(
            pdf: pdf, image: image, text: text, supportsDocuments: provider.supportsDocuments,
            supportsImages: provider.capabilities.supportsImages)
    }
}
