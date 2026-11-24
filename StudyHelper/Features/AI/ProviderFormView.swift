import StudyAI
import SwiftUI

/// Add or edit one AI provider configuration. The API key is saved to the Keychain right away when the user fetches
/// models or tests the connection (those calls need it); a new provider that is not saved loses its key again.
struct ProviderFormView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var draft: ProviderConfiguration
    @State private var apiKey = ""
    @State private var nameEdited: Bool
    @State private var models: [ModelInfo] = []
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?
    @State private var makeDefault: Bool
    @State private var saved = false
    @State private var confirmDelete = false
    @State private var keyError: String?

    /// New provider.
    init() {
        isNew = true
        _draft = State(initialValue: ProviderConfiguration(name: ProviderKind.claude.defaultName, kind: .claude, model: ""))
        _nameEdited = State(initialValue: false)
        _makeDefault = State(initialValue: false)
    }

    /// Existing provider.
    init(editing configuration: ProviderConfiguration, isDefault: Bool) {
        isNew = false
        _draft = State(initialValue: configuration)
        _nameEdited = State(initialValue: true)
        _makeDefault = State(initialValue: isDefault)
    }

    private var capabilities: ProviderCapabilities { ProviderFactory.capabilities(of: draft) }
    private var appleAvailability: AppleModelAvailability { .current }
    private var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty || ai.hasKey(for: draft.id) }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !draft.model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch draft.kind {
        case .claude, .openAI: return hasKey
        case .openAICompatible: return !(draft.baseURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .appleFoundation: return appleAvailability.isAvailable
        case .mock: return true
        }
    }

    private var reasoningBinding: Binding<ReasoningLevel> {
        Binding(
            get: { draft.reasoning ?? capabilities.defaultReasoning ?? capabilities.reasoningLevels.first ?? .off },
            set: { draft.reasoning = $0 })
    }

    var body: some View {
        Form {
            providerSection
            if draft.kind != .appleFoundation { modelSection } else { appleModelSection }
            if !models.isEmpty || !draft.model.isEmpty { capabilitySection }
            Section {
                Toggle("Als Standard verwenden", isOn: $makeDefault)
                    .accessibilityIdentifier("defaultToggle")
            }
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Verbindung testen")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting || !canTest)
                .accessibilityIdentifier("testConnectionButton")
                if let testResult {
                    Label(testResult.message, systemImage: testResult.isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(testResult.isSuccess ? .green : .red)
                        .accessibilityIdentifier("connectionResult")
                }
            } footer: {
                Text("Der Test sendet eine winzige Anfrage („Antworte nur mit OK.“). Sie erscheint im Anfrage-Log.")
            }
            if !isNew {
                Section {
                    Button("Anbieter löschen", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("deleteProviderButton")
                }
            }
        }
        .navigationTitle(isNew ? "Anbieter hinzufügen" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveProviderButton")
            }
        }
        .alert("Anbieter löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                ai.delete(draft.id)
                saved = true
                dismiss()
            }
            .accessibilityIdentifier("confirmDeleteProviderButton")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("„\(draft.name)“ und der gespeicherte API-Key werden gelöscht.")
        }
        .errorAlert($keyError)
        .onDisappear {
            if isNew && !saved { ai.deleteKey(for: draft.id) }
        }
    }

    // MARK: Sections

    private var providerSection: some View {
        Section {
            Picker("Art", selection: kindBinding) {
                ForEach(ProviderKind.selectable, id: \.self) { kind in
                    Text(kind.germanName).tag(kind)
                        .disabled(kind == .appleFoundation && !appleAvailability.isAvailable)
                }
            }
            .disabled(!isNew)
            .accessibilityIdentifier("providerKindPicker")
            TextField("Name", text: nameBinding)
                .accessibilityIdentifier("providerNameField")
            if draft.kind == .openAICompatible {
                TextField("Adresse, z. B. http://192.168.0.5:11434", text: Binding(
                    get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("providerBaseURLField")
            }
            if draft.kind.allowsKey {
                SecureField(
                    ai.hasKey(for: draft.id) ? "API-Key: gespeichert" : (draft.kind.needsKey ? "API-Key" : "API-Key (optional)"),
                    text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("providerKeyField")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if draft.kind.allowsKey {
                    Text("Der Key wird nur in der Keychain dieses Geräts gespeichert, nie im Log oder in den Einstellungen.")
                }
                if !appleAvailability.isAvailable {
                    Text("Apple On-Device: \(appleAvailability.germanDescription)")
                }
            }
        }
    }

    private var modelSection: some View {
        Section {
            Button {
                Task { await fetchModels() }
            } label: {
                HStack {
                    Text("Modelle abrufen")
                    if isFetching { Spacer(); ProgressView() }
                }
            }
            .disabled(isFetching || !canFetch)
            .accessibilityIdentifier("fetchModelsButton")
            if let fetchError {
                Text(fetchError).foregroundStyle(.red).font(.footnote)
                    .accessibilityIdentifier("fetchModelsError")
            }
            if models.isEmpty {
                TextField("Modell", text: Binding(
                    get: { draft.model }, set: { draft.model = $0; draft.cachedCapabilities = nil }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("modelField")
            } else {
                Picker("Modell", selection: modelBinding) {
                    if !models.contains(where: { $0.id == draft.model }) {
                        Text(draft.model.isEmpty ? "Bitte wählen" : draft.model).tag(draft.model)
                    }
                    ForEach(models) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("modelPicker")
            }
        } header: {
            Text("Modell")
        }
    }

    private var appleModelSection: some View {
        Section {
            LabeledContent("Modell", value: "Apple-Modell (auf dem Gerät)")
        }
        .onAppear { if draft.model.isEmpty { draft.model = "apple-foundation" } }
    }

    private var capabilitySection: some View {
        Section {
            if !capabilities.reasoningLevels.isEmpty {
                Picker("Denktiefe", selection: reasoningBinding) {
                    ForEach(capabilities.reasoningLevels, id: \.self) { Text($0.germanName).tag($0) }
                }
                .accessibilityIdentifier("reasoningPicker")
            }
            if draft.imageSupportIsUnknown {
                Toggle("Modell kann Bilder verarbeiten", isOn: Binding(
                    get: { draft.imageSupportOverride ?? false }, set: { draft.imageSupportOverride = $0 }))
                    .accessibilityIdentifier("imageToggle")
            } else {
                LabeledContent("Bilder", value: capabilities.supportsImages ? "werden unterstützt" : "werden nicht unterstützt")
                    .accessibilityIdentifier("imageInfo")
            }
        } header: {
            Text("Fähigkeiten")
        }
    }

    // MARK: Bindings and actions

    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { draft.kind },
            set: { kind in
                let oldDefault = draft.kind.defaultName
                draft.kind = kind
                if !nameEdited || draft.name == oldDefault { draft.name = kind.defaultName }
                draft.model = kind == .appleFoundation ? "apple-foundation" : ""
                draft.cachedCapabilities = nil
                draft.reasoning = nil
                draft.imageSupportOverride = nil
                draft.baseURL = nil
                models = []
                fetchError = nil
                testResult = nil
            })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { draft.name }, set: { draft.name = $0; nameEdited = true })
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model },
            set: { id in
                draft.model = id
                guard let info = models.first(where: { $0.id == id }) else { return }
                draft.cachedCapabilities = info.capabilities
                if let level = draft.reasoning, !info.capabilities.reasoningLevels.contains(level) { draft.reasoning = nil }
            })
    }

    private var canFetch: Bool {
        switch draft.kind {
        case .claude, .openAI: return hasKey
        case .openAICompatible: return !(draft.baseURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    private var canTest: Bool {
        !draft.model.isEmpty && (draft.kind != .appleFoundation || appleAvailability.isAvailable) && (!draft.kind.needsKey || hasKey)
    }

    private func commitKey() -> Bool {
        guard draft.kind.allowsKey else { return true }
        do {
            try ai.saveKey(apiKey, for: draft.id)
            apiKey = ""
            return true
        } catch {
            keyError = "Der API-Key konnte nicht in der Keychain gespeichert werden."
            return false
        }
    }

    private func fetchModels() async {
        guard commitKey() else { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            let list = try await ai.fetchModels(for: draft)
            models = list
            if let info = list.first(where: { $0.id == draft.model }) {
                draft.cachedCapabilities = info.capabilities
            } else if let first = list.first {
                modelBinding.wrappedValue = first.id
            }
            if list.isEmpty { fetchError = "Der Anbieter hat keine Modelle gemeldet." }
        } catch {
            fetchError = AIService.message(for: error)
        }
    }

    private func testConnection() async {
        guard commitKey() else { return }
        isTesting = true
        testResult = nil
        testResult = await ai.testConnection(configuration: draft)
        isTesting = false
    }

    private func save() {
        guard commitKey() else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.model = draft.model.trimmingCharacters(in: .whitespaces)
        if draft.kind == .openAICompatible { draft.baseURL = draft.baseURL?.trimmingCharacters(in: .whitespaces) }
        if isNew {
            ai.add(draft, makeDefault: makeDefault)
        } else {
            ai.update(draft)
            if makeDefault { ai.setDefault(draft.id) }
        }
        saved = true
        dismiss()
    }
}
