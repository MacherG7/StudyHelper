import SwiftUI

extension View {
    /// Shows `message` in a German alert; every failed repository call ends here (no `try!`).
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Das hat nicht geklappt",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// A colored info strip at the top of a screen (warnings, errors, notices).
struct InfoBanner<Actions: View>: View {
    enum Style { case info, warning, error }

    let style: Style
    let text: String
    @ViewBuilder var actions: () -> Actions

    init(_ text: String, style: Style = .info, @ViewBuilder actions: @escaping () -> Actions) {
        self.text = text
        self.style = style
        self.actions = actions
    }

    private var tint: Color {
        switch style {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private var symbol: String {
        switch style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

extension InfoBanner where Actions == EmptyView {
    init(_ text: String, style: Style = .info) {
        self.init(text, style: style) { EmptyView() }
    }
}
