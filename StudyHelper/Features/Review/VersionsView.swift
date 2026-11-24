import StudyCore
import StudyData
import SwiftUI

/// All digitizations of a page (SPEC §2: the old state stays as a version) with "Wiederherstellen".
struct VersionsView: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @Environment(ImportCoordinator.self) private var coordinator
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                let versions = source.sortedDigitizations.reversed()
                if versions.isEmpty {
                    Text("Diese Seite wurde noch nicht erkannt.").foregroundStyle(.secondary)
                }
                ForEach(Array(versions), id: \.id) { version in
                    VersionRow(version: version, canRestore: !coordinator.isRunning) {
                        restore(version)
                    }
                }
            }
            .navigationTitle("Versionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .errorAlert($errorMessage)
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
    let onRestore: () -> Void

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
            if !version.isCurrent {
                Button("Wiederherstellen", systemImage: "arrow.uturn.backward", action: onRestore)
                    .buttonStyle(.bordered)
                    .disabled(!canRestore)
                    .accessibilityIdentifier("restoreVersionButton")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
