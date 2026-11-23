import StudyData
import SwiftUI

/// Review screen of one import: pages of the batch with a pager, re-recognition and versions.
struct ReviewScreen: View {
    let batch: ImportBatch
    @Environment(ImportCoordinator.self) private var coordinator
    @State private var pageIndex = 0
    @State private var showVersions = false
    @State private var rerunScope: RerunScope?

    enum RerunScope: Identifiable {
        case page, all
        var id: Self { self }
    }

    var body: some View {
        let sources = batch.sortedSources
        let index = min(pageIndex, max(sources.count - 1, 0))
        let current = sources.indices.contains(index) ? sources[index] : nil
        VStack(spacing: 0) {
            if sources.count > 1 {
                PageStepper(sources: sources, index: Binding(get: { index }, set: { pageIndex = $0 }))
            }
            if let current {
                ReviewPageView(source: current, batch: batch)
                    .id(current.id)
            } else {
                ContentUnavailableView("Keine Seiten", systemImage: "doc")
            }
        }
        .navigationTitle(batch.originalFileName ?? batch.kind.germanName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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

/// "‹  Seite 2 von 5  ›" with a menu to jump to a page.
private struct PageStepper: View {
    let sources: [Source]
    @Binding var index: Int
    @State private var summariesCache = DerivedValue<[PageSummary]>()

    var body: some View {
        let summaries = summariesCache.value(key: sources.map(\.id)) { sources.map { PageSummary($0) } }
        HStack {
            Button("Vorherige Seite", systemImage: "chevron.left") { index = max(index - 1, 0) }
                .labelStyle(.iconOnly)
                .disabled(index == 0)
                .accessibilityIdentifier("previousPageButton")
            Spacer()
            Menu {
                ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                    let page = summaries.indices.contains(i) ? summaries[i] : PageSummary(source)
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
