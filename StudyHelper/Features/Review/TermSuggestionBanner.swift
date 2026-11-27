import StudyCore
import StudyData
import SwiftUI

/// How the app finds possible subject terms ("Fachbegriffe") in an import: words the spell checker does not know
/// that look like terms (`TermSuggestions`). UI tests replace it with a deterministic rule.
enum AppTermSuggestions {
    typealias Provider = @Sendable ([RecognizedLine], any SpellChecking, Set<String>) -> [String]

    static var provider: Provider = { lines, checker, known in
        TermSuggestions.candidates(lines: lines, checker: checker, known: known)
    }

    /// Rule of the UI tests: every capitalized word of six letters or more that the checker does not know and that is
    /// no known term, in order of appearance.
    static let uiTestProvider: Provider = { lines, checker, known in
        let knownLowercased = Set(known.map { $0.lowercased() })
        var seen: Set<String> = []
        var result: [String] = []
        for line in lines.sorted(by: { $0.order < $1.order }) {
            for token in WordReview.tokens(of: line) {
                let word = token.core
                guard word.count >= 6, word.first?.isUppercase == true, !checker.isKnown(word),
                      !knownLowercased.contains(word.lowercased()), seen.insert(word.lowercased()).inserted
                else { continue }
                result.append(word)
            }
        }
        return result
    }
}

/// "Banner dismissed" per import, remembered in `UserDefaults`.
enum TermSuggestionPreference {
    static func key(for batchID: UUID) -> String { "termSuggestionsDismissed.\(batchID.uuidString)" }

    static func isDismissed(_ batchID: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(for: batchID))
    }

    static func dismiss(_ batchID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(for: batchID))
    }

    static func reset(_ batchID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: batchID))
    }
}

/// "Mögliche Fachbegriffe: A, B, C … [Übernehmen] [Auswählen]" above the pages of an import. Adopting adds the terms
/// to the subject, so that they count as correctly spelled everywhere and help the recognition.
struct TermSuggestionBanner: View {
    let terms: [String]
    let onAdopt: ([String]) -> Void
    let onDismiss: () -> Void
    @State private var selecting = false

    /// Terms named in the line; the rest is "…".
    static let shownCount = 6

    var body: some View {
        let shown = terms.prefix(Self.shownCount).joined(separator: ", ")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.book.closed").foregroundStyle(.tint).accessibilityHidden(true)
                Text("Mögliche Fachbegriffe: \(shown)\(terms.count > Self.shownCount ? " …" : "")")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("termBannerText")
                Spacer(minLength: 0)
                Button("Ausblenden", systemImage: "xmark.circle.fill", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dismissTermsButton")
            }
            HStack(spacing: 8) {
                Button("Übernehmen") { onAdopt(terms) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(terms.count == 1 ? "Fachbegriff übernehmen" : "\(terms.count) Fachbegriffe übernehmen")
                    .accessibilityIdentifier("adoptTermsButton")
                Button("Auswählen") { selecting = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("selectTermsButton")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("termBanner")
        .sheet(isPresented: $selecting) {
            TermSelectionSheet(terms: terms) { chosen in
                selecting = false
                onAdopt(chosen)
            }
        }
    }
}

/// Choose which of the suggested terms to adopt.
struct TermSelectionSheet: View {
    let terms: [String]
    let onAdopt: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(terms: [String], onAdopt: @escaping ([String]) -> Void) {
        self.terms = terms
        self.onAdopt = onAdopt
        _selected = State(initialValue: Set(terms))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(terms.enumerated()), id: \.offset) { index, term in
                        Toggle(term, isOn: Binding(
                            get: { selected.contains(term) },
                            set: { if $0 { selected.insert(term) } else { selected.remove(term) } }))
                            .accessibilityIdentifier("termToggle-\(index)")
                    }
                } footer: {
                    Text("Übernommene Fachbegriffe gelten im ganzen Fach als richtig geschrieben und helfen der Texterkennung.")
                }
            }
            .navigationTitle("Fachbegriffe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen (\(selected.count))") {
                        onAdopt(terms.filter(selected.contains))
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("adoptSelectedTermsButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
