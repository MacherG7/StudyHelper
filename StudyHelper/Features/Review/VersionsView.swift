import QuickLook
import StudyCore
import StudyData
import SwiftUI

/// All digitizations of a page (SPEC §2: the old state stays as a version) with "Wiederherstellen".
struct VersionsView: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(\.digitalPageStore) private var digitalPages
    @State private var pdfPreview = DigitalPDFPreview()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                let versions = source.sortedDigitizations.reversed()
                if versions.isEmpty {
                    Text("Diese Seite wurde noch nicht erkannt.").foregroundStyle(.secondary)
                }
                ForEach(Array(versions), id: \.id) { version in
                    VersionRow(
                        version: version, canRestore: !coordinator.isRunning, canShowPDF: !pdfPreview.isBuilding,
                        onRestore: { restore(version) }, onShowPDF: { showPDF(of: version) })
                }
            }
            .navigationTitle("Versionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .errorAlert($errorMessage)
            .errorAlert(Bindable(pdfPreview).errorMessage)
            .quickLookPreview(Bindable(pdfPreview).url)
            .onDisappear { pdfPreview.cancel() }
        }
    }

    private func showPDF(of version: Digitization) {
        let base = source.batch.map(DigitalPageStore.baseName(of:)) ?? "Seite"
        pdfPreview.open(with: digitalPages, base: base, suffix: "Version \(version.versionNumber)") {
            [try DigitalPageRequest.make(source: source, digitization: version)]
        }
    }

    private func restore(_ version: Digitization) {
        do {
            try repository?.restoreVersion(version)
            coordinator.reportImpact(of: [source])
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct VersionRow: View {
    let version: Digitization
    let canRestore: Bool
    let canShowPDF: Bool
    let onRestore: () -> Void
    let onShowPDF: () -> Void

    var body: some View {
        let meta = version.metadata
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Version \(version.versionNumber)").font(.headline)
                if version.isCurrent {
                    Text("aktuell")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.green.opacity(0.25), in: Capsule())
                }
                if version.isDamaged {
                    Text("beschädigt")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.red.opacity(0.25), in: Capsule())
                }
            }
            Text(version.createdAt.germanShort).font(.subheadline).foregroundStyle(.secondary)
            Group {
                Text("Methode: \(meta.method.germanName)\(meta.passes > 1 ? " (\(meta.passes) Durchläufe)" : "")")
                if let engine = meta.engineVersion ?? meta.modelName {
                    Text("Engine: \(engine)")
                }
                Text("Gerät: \(meta.deviceModel.isEmpty ? "unbekannt" : meta.deviceModel) · \(meta.osVersion.isEmpty ? "unbekannt" : meta.osVersion)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Button("Als PDF ansehen", systemImage: "doc.text.magnifyingglass", action: onShowPDF)
                    .buttonStyle(.bordered)
                    .disabled(!canShowPDF || version.hasUnreadableData)
                    .accessibilityIdentifier("versionPDFButton")
                if !version.isCurrent {
                    Button("Wiederherstellen", systemImage: "arrow.uturn.backward", action: onRestore)
                        .buttonStyle(.bordered)
                        .disabled(!canRestore)
                        .accessibilityIdentifier("restoreVersionButton")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
