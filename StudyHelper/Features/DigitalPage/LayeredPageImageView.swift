import StudyCore
import StudyData
import StudyImport
import SwiftUI

/// The page image with the switch "Handschrift | Textebene" above it. Wraps `PageImageView`, which keeps zoom,
/// line overlays, tap selection and the marked area. Handwriting is the stored page image; the text layer is built
/// by `DigitalPageStore` (cached) and shown after a short progress. The choice is remembered per subject.
struct LayeredPageImageView: View {
    let source: Source
    /// The stored page image (handwriting layer).
    let image: UIImage
    /// What `PageImageView` draws over the page (tap targets); may be empty.
    let lines: [RecognizedLine]
    let highlights: [RecognizedHighlight]
    @Binding var selectedLineID: UUID?
    let onlyOpen: Bool
    var markedRect: NormalizedRect?
    /// Marked words and illegible lines of the page, and the tap on a marked word (both layers show them).
    var review = PageWordReview()
    /// False while the page is locked (damaged, being recognized): the word frames cannot be tapped.
    var wordsEnabled = true
    var onWordTap: (UUID, Int) -> Void = { _, _ in }

    @Environment(\.digitalPageStore) private var store
    @AppStorage private var storedMode: DigitalPageMode
    @State private var contentCache = DerivedValue<PageContent>()
    @State private var textImage: UIImage?
    /// German message if the text layer could not be built; the handwriting is shown instead.
    @State private var failure: String?
    @State private var isLoading = false
    /// Counts taps on the picker, so that choosing "Textebene" again retries after a failure.
    @State private var attempt = 0

    init(
        source: Source, image: UIImage, lines: [RecognizedLine], highlights: [RecognizedHighlight],
        selectedLineID: Binding<UUID?>, onlyOpen: Bool, markedRect: NormalizedRect? = nil,
        review: PageWordReview = PageWordReview(), wordsEnabled: Bool = true,
        onWordTap: @escaping (UUID, Int) -> Void = { _, _ in }
    ) {
        self.source = source
        self.image = image
        self.lines = lines
        self.highlights = highlights
        _selectedLineID = selectedLineID
        self.onlyOpen = onlyOpen
        self.markedRect = markedRect
        self.review = review
        self.wordsEnabled = wordsEnabled
        self.onWordTap = onWordTap
        _storedMode = AppStorage(
            wrappedValue: .handwriting, DigitalPageModePreference.key(for: source.batch?.subject?.id))
    }

    /// What the text layer is built from; decoded once per change of the page's data.
    private struct PageContent {
        var available = false
        var token = 0

        init() {}

        init(_ source: Source) {
            guard let digitization = source.currentDigitization, !digitization.hasUnreadableData else { return }
            available = true
            var hasher = Hasher()
            hasher.combine(digitization.id)
            hasher.combine(digitization.lines)
            hasher.combine(digitization.highlights)
            token = hasher.finalize()
        }
    }

    private struct LayerKey: Hashable {
        var wantsText: Bool
        var token: Int
        var attempt: Int
    }

    var body: some View {
        let content = contentCache.value(key: source.id) { PageContent(source) }
        let wantsText = content.available && storedMode == .textLayer
        let showsText = wantsText && textImage != nil && failure == nil
        VStack(spacing: 0) {
            if content.available {
                picker(wantsText: wantsText && failure == nil)
            }
            if let failure, wantsText {
                InfoBanner("\(failure) Du siehst die Handschrift.", style: .warning)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("pageLayerFailure")
            }
            PageImageView(
                image: showsText ? (textImage ?? image) : image, lines: lines, highlights: highlights,
                selectedLineID: $selectedLineID, onlyOpen: onlyOpen, review: review, wordsEnabled: wordsEnabled, onWordTap: onWordTap,
                markedRect: markedRect, layerName: (showsText ? DigitalPageMode.textLayer : .handwriting).germanName)
                .overlay {
                    if wantsText && isLoading {
                        ProgressView("Textebene wird erstellt…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("pageLayerLoading")
                    }
                }
        }
        .task(id: LayerKey(wantsText: wantsText, token: content.token, attempt: attempt)) {
            await loadTextLayer(wanted: wantsText)
        }
    }

    private func picker(wantsText: Bool) -> some View {
        Picker(
            "Ebene der Seite",
            selection: Binding(
                get: { wantsText ? DigitalPageMode.textLayer : .handwriting },
                set: { newValue in
                    storedMode = newValue
                    failure = nil
                    attempt += 1
                })
        ) {
            Text(DigitalPageMode.handwriting.germanName).tag(DigitalPageMode.handwriting)
            Text(DigitalPageMode.textLayer.germanName).tag(DigitalPageMode.textLayer)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("pageLayerPicker")
    }

    private func loadTextLayer(wanted: Bool) async {
        guard wanted else {
            // Do not keep a full image in memory while the handwriting is shown; the file cache makes coming back cheap.
            textImage = nil
            failure = nil
            isLoading = false
            return
        }
        guard let store else {
            failure = DigitalPageStoreError.unavailable.localizedDescription
            return
        }
        isLoading = true
        failure = nil
        do {
            let request = try DigitalPageRequest.make(source: source)
            let url = try await store.imageFile(for: request, mode: .textLayer)
            let loaded = await UIImage(contentsOfFile: url.path)?.byPreparingForDisplay()
            try Task.checkCancellation()
            guard let loaded else { throw DigitalPageError.renderingFailed }
            textImage = loaded
            isLoading = false
        } catch is CancellationError {
            // A newer task (another layer or new text) takes over and manages the state.
        } catch {
            textImage = nil
            failure = error.localizedDescription
            isLoading = false
        }
    }
}
