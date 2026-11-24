import StudyAI
import StudyCore
import SwiftUI

/// Built-in prices plus the user's overrides; every price can be changed per model.
struct PriceTableView: View {
    @Environment(AIService.self) private var ai

    private var models: [String] {
        Set(PriceTable.defaults.keys).union(ai.settings.priceOverrides.keys).sorted()
    }

    var body: some View {
        List {
            Section {
                ForEach(models, id: \.self) { model in
                    NavigationLink {
                        PriceEditView(model: model, isNewModel: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model).font(.body.monospaced())
                                if ai.settings.priceOverrides[model] != nil {
                                    Text("angepasst").font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            if let price = ai.settings.priceTable.price(for: model) {
                                Text("Eingabe \(PriceFormat.number(price.input)) · Ausgabe \(PriceFormat.number(price.output)) $")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("priceRow-\(model)")
                }
            } header: {
                Text("Preise je 1 Mio. Tokens in US-Dollar")
            } footer: {
                Text("Alle Kosten sind geschätzt. Preise ändern sich; bei Abweichungen trägst du hier den aktuellen Preis ein.")
            }
            Section {
                NavigationLink {
                    PriceEditView(model: "", isNewModel: true)
                } label: {
                    Label("Preis für anderes Modell hinzufügen", systemImage: "plus")
                }
                .accessibilityIdentifier("addPriceButton")
                if !ai.settings.priceOverrides.isEmpty {
                    Button("Alle Anpassungen zurücksetzen", role: .destructive) { ai.resetPriceOverrides() }
                        .accessibilityIdentifier("resetPricesButton")
                }
            }
        }
        .navigationTitle("Preistabelle")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum PriceFormat {
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...4))) }

    static func parse(_ text: String) -> Double? {
        let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        guard let value, value >= 0, value.isFinite else { return nil }
        return value
    }
}

/// Price of one model: input, output, cache read, cache write (USD per 1 million tokens).
struct PriceEditView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss

    let isNewModel: Bool
    @State private var model: String
    @State private var input: String
    @State private var output: String
    @State private var cacheRead: String
    @State private var cacheWrite: String

    init(model: String, isNewModel: Bool) {
        self.isNewModel = isNewModel
        _model = State(initialValue: model)
        _input = State(initialValue: "")
        _output = State(initialValue: "")
        _cacheRead = State(initialValue: "")
        _cacheWrite = State(initialValue: "")
    }

    /// Empty cache fields fall back to the usual ratios (read 10 %, write 125 % of the input price).
    private var parsed: ModelPrice? {
        guard let input = PriceFormat.parse(input), let output = PriceFormat.parse(output) else { return nil }
        let read = cacheRead.trimmingCharacters(in: .whitespaces).isEmpty ? input * 0.1 : PriceFormat.parse(cacheRead)
        let write = cacheWrite.trimmingCharacters(in: .whitespaces).isEmpty ? input * 1.25 : PriceFormat.parse(cacheWrite)
        guard let read, let write else { return nil }
        var base = ai.settings.priceTable.price(for: model.trimmingCharacters(in: .whitespaces))
            ?? ModelPrice(input: input, output: output)
        base.input = input
        base.output = output
        base.cacheRead = read
        base.cacheWrite = write
        return base
    }

    var body: some View {
        Form {
            Section {
                if isNewModel {
                    TextField("Modell-ID", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("priceModelField")
                } else {
                    LabeledContent("Modell", value: model)
                }
            }
            Section {
                field("Eingabe", $input, id: "priceInputField")
                field("Ausgabe", $output, id: "priceOutputField")
                field("Cache lesen", $cacheRead, id: "priceCacheReadField")
                field("Cache schreiben", $cacheWrite, id: "priceCacheWriteField")
            } header: {
                Text("US-Dollar je 1 Mio. Tokens")
            } footer: {
                Text("Alle Kosten sind geschätzt.")
            }
            if !isNewModel, ai.settings.priceOverrides[model] != nil {
                Section {
                    Button("Auf Standard zurücksetzen", role: .destructive) {
                        ai.setPriceOverride(nil, for: model)
                        dismiss()
                    }
                    .accessibilityIdentifier("resetPriceButton")
                }
            }
        }
        .navigationTitle(isNewModel ? "Neuer Preis" : model)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    guard let parsed else { return }
                    ai.setPriceOverride(parsed, for: model.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .disabled(parsed == nil || model.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("savePriceButton")
            }
        }
        .onAppear(perform: load)
    }

    private func field(_ title: String, _ text: Binding<String>, id: String) -> some View {
        LabeledContent(title) {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }

    private func load() {
        guard input.isEmpty, let price = ai.settings.priceTable.price(for: model) else { return }
        input = PriceFormat.number(price.input)
        output = PriceFormat.number(price.output)
        cacheRead = PriceFormat.number(price.cacheRead)
        cacheWrite = PriceFormat.number(price.cacheWrite)
    }
}
