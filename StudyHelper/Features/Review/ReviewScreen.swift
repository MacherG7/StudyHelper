import QuickLook
import StudyData
import SwiftUI

/// Review screen of one import: pages of the batch with a pager, re-recognition and versions.
struct ReviewScreen: View {
    let batch: ImportBatch
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(\.digitalPageStore) private var digitalPages
    @State private var pdfPreview = DigitalPDFPreview()
    @State private var pageIndex = 0
    @State private var showVersions = false
    @State private var rerunScope: RerunScope?
    @State private var loader = PageSummaryLoader()
    @State private var termsDismissed = false
    @State private var errorMessage: String?
    @Environment(\.studyRepository) private var repository

    enum RerunScope: Identifiable {
        case page, all
        var id: Self { self }
    }

    var body: some View {
        let sources = batch.sortedSources
        let index = min(pageIndex, max(sources.count - 1, 0))
        let current = sources.indices.contains(index) ? sources[index] : nil
        VStack(spacing: 0) {
            if let terms = loader.termCandidates, !terms.isEmpty, !termsDismissed {
                TermSuggestionBanner(terms: terms, onAdopt: adopt, onDismiss: dismissTerms)
            }
            if sources.count > 1 {
                PageStepper(
                    sources: sources, summaries: loader.pages ?? [], index: Binding(get: { index }, set: { pageIndex = $0 }))
            }
            if let current {
                ReviewPageView(source: current, batch: batch)
                    .id(current.id)
            } else {
                ContentUnavailableView("Keine Seiten", systemImage: "doc")
            }
        }
        .errorAlert($errorMessage)
        .navigationTitle(batch.originalFileName ?? batch.kind.germanName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if pdfPreview.isBuilding {
                    ProgressView().accessibilityLabel("PDF wird erstellt").accessibilityIdentifier("digitalPDFProgress")
                }
                Button("Als PDF ansehen", systemImage: "doc.text.magnifyingglass") {
                    pdfPreview.open(with: digitalPages, base: DigitalPageStore.baseName(of: batch)) {
                        try DigitalPageRequest.all(of: batch)
                    }
                }
                .disabled(current == nil || pdfPreview.isBuilding)
                .accessibilityIdentifier("digitalPDFButton")
                Button("Versionen", systemImage: "clock.arrow.circlepath") { showVersions = true }
                    .disabled(current == nil)
                    .accessibilityIdentifier("versionsButton")
                Menu {
                    Button("Diese Seite neu erkennen", systemImage: "doc.text.viewfinder") { rerunScope = .page }
                    if sources.count > 1 {
                        Button("Ganzen Import neu erkennen", systemImage: "doc.on.doc") { rerunScope = .all }
                    }
                } label: {
                    Label("Neu erkennen", systemImage: "arrow.clockwise")
                }
                .disabled(current == nil || coordinator.isRunning)
                .accessibilityIdentifier("reRecognizeButton")
            }
        }
        .task(id: sources.map(\.id), priority: .utility) {
            termsDismissed = TermSuggestionPreference.isDismissed(batch.id)
            let checker = AppSpellChecker.shared
            await loader.run(sources: { batch.sortedSources }, checker: checker, suggestTerms: true)
        }
        .quickLookPreview(Bindable(pdfPreview).url)
        .errorAlert(Bindable(pdfPreview).errorMessage)
        .onDisappear { pdfPreview.cancel() }
        .sheet(isPresented: $showVersions) {
            if let current { VersionsView(source: current) }
        }
        .confirmationDialog(
            rerunScope == .all ? "Ganzen Import neu erkennen?" : "Diese Seite neu erkennen?",
            isPresented: Binding(get: { rerunScope != nil }, set: { if !$0 { rerunScope = nil } }),
            titleVisibility: .visible
        ) {
            Button("Neu erkennen") {
                switch rerunScope {
                case .all: coordinator.reRecognize(sources, in: batch)
                case .page: if let current { coordinator.reRecognize([current], in: batch) }
                case nil: break
                }
                rerunScope = nil
            }
            .accessibilityIdentifier("confirmReRecognizeButton")
            Button("Abbrechen", role: .cancel) { rerunScope = nil }
        } message: {
            Text("Deine manuellen Korrekturen bleiben erhalten und werden auf das neue Ergebnis angewendet. Der bisherige Stand bleibt als Version gespeichert; du kannst ihn unter „Versionen“ wiederherstellen.")
        }
    }
}

extension ReviewScreen {
    /// Adds the suggested terms to the subject: the marks of these words disappear everywhere.
    private func adopt(_ terms: [String]) {
        guard let repository, let subject = batch.subject else { return }
        do {
            for term in terms { try repository.addConfirmedTerm(term, to: subject) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissTerms() {
        TermSuggestionPreference.dismiss(batch.id)
        termsDismissed = true
    }
}

/// "‹  Seite 2 von 5  ›" with a menu to jump to a page.
private struct PageStepper: View {
    let sources: [Source]
    /// The open counts per page, computed in the background; the menu shows none until they are ready.
    let summaries: [PageSummary]
    @Binding var index: Int

    var body: some View {
        HStack {
            Button("Vorherige Seite", systemImage: "chevron.left") { index = max(index - 1, 0) }
                .labelStyle(.iconOnly)
                .disabled(index == 0)
                .accessibilityIdentifier("previousPageButton")
            Spacer()
            Menu {
                ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                    let page = summaries.indices.contains(i) ? summaries[i] : PageSummary()
                    Button {
                        index = i
                    } label: {
                        if page.unreadable {
                            Text("Seite \(i + 1) · beschädigt")
                        } else {
                            Text(page.open > 0 ? "Seite \(i + 1) · \(page.open) offen" : "Seite \(i + 1)")
                        }
                    }
                }
            } label: {
                Text("Seite \(index + 1) von \(sources.count)")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("pageMenu")
            Spacer()
            Button("Nächste Seite", systemImage: "chevron.right") { index = min(index + 1, sources.count - 1) }
                .labelStyle(.iconOnly)
                .disabled(index >= sources.count - 1)
                .accessibilityIdentifier("nextPageButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
