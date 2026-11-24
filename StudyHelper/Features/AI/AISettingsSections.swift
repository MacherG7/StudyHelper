import StudyAI
import SwiftUI

/// Settings sections for the AI layer: providers, tasks, costs, developer mode.
struct AISettingsSections: View {
    @Environment(AIService.self) private var ai
    @State private var rateText = ""

    var body: some View {
        providersSection
        tasksSection
        costsSection
        developerSection
    }

    // MARK: Providers

    private var providersSection: some View {
        Section {
            ForEach(ai.configurations) { configuration in
                NavigationLink {
                    ProviderFormView(editing: configuration, isDefault: configuration.id == ai.defaultConfigurationID)
                } label: {
                    ProviderRow(configuration: configuration, isDefault: configuration.id == ai.defaultConfigurationID)
                }
                .accessibilityIdentifier("providerRow-\(configuration.name)")
            }
            NavigationLink {
                ProviderFormView()
            } label: {
                Label("Anbieter hinzufügen", systemImage: "plus")
            }
            .accessibilityIdentifier("addProviderButton")
        } header: {
            Text("KI-Anbieter")
        } footer: {
            if ai.configurations.isEmpty {
                Text("Noch kein Anbieter eingerichtet. Ohne Anbieter bleibt die KI aus; importierte Texte und die manuelle Strukturierung funktionieren trotzdem.")
            }
        }
    }

    // MARK: Tasks

    private var tasksSection: some View {
        Section {
            Picker("Digitalisierung", selection: Binding(
                get: { ai.settings.digitizationProviderID },
                set: { ai.setDigitizationProvider($0) })
            ) {
                Text("Wie Standard").tag(UUID?.none)
                ForEach(ai.configurations) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .accessibilityIdentifier("digitizationProviderPicker")
            ForEach(AITask.reasoningTasks, id: \.self) { task in
                Picker(task.germanName, selection: Binding(
                    get: { ai.settings.reasoningOverrides[task] },
                    set: { ai.setReasoningOverride($0, for: task) })
                ) {
                    Text("Wie Anbieter").tag(ReasoningLevel?.none)
                    ForEach(ReasoningLevel.allCases, id: \.self) { Text($0.germanName).tag(ReasoningLevel?.some($0)) }
                }
                .accessibilityIdentifier("reasoningOverride-\(task.rawValue)")
            }
        } header: {
            Text("Aufgaben")
        } footer: {
            Text("Die Denktiefe pro Aufgabe gilt nur, wenn das Modell sie unterstützt; sonst gilt die Einstellung des Anbieters.")
        }
    }

    // MARK: Costs

    private var costsSection: some View {
        Section {
            LabeledContent("1 US-Dollar in Euro") {
                TextField("0,86", text: $rateText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("usdRateField")
                    .onChange(of: rateText) { _, text in
                        let normalized = text.replacingOccurrences(of: ",", with: ".")
                        if let value = Double(normalized), value > 0 { ai.setUSDToEURRate(value) }
                    }
            }
            NavigationLink("Preistabelle") { PriceTableView() }
                .accessibilityIdentifier("priceTableLink")
        } header: {
            Text("Kosten")
        } footer: {
            Text("Alle Kosten sind geschätzt. Preise und Wechselkurs können abweichen.")
        }
        .onAppear {
            if rateText.isEmpty { rateText = ai.settings.usdToEurRate.formatted(.number.precision(.fractionLength(2...4))) }
        }
    }

    // MARK: Developer

    private var developerSection: some View {
        Section {
            Toggle("Developer-Modus", isOn: Binding(
                get: { ai.settings.developerModeEnabled }, set: { ai.setDeveloperMode($0) }))
                .accessibilityIdentifier("developerModeToggle")
            if ai.settings.developerModeEnabled {
                NavigationLink("Anfrage-Log") { RequestLogView() }
                    .accessibilityIdentifier("requestLogLink")
            }
        } header: {
            Text("Entwickler")
        } footer: {
            Text("Zeigt im Anfrage-Log, was an die KI gesendet wurde, was zurückkam und was es gekostet hat.")
        }
    }
}

private struct ProviderRow: View {
    let configuration: ProviderConfiguration
    let isDefault: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name)
                Text("\(configuration.kind.germanName) · \(configuration.model)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Standard")
            }
        }
    }
}
