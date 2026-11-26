import StudyAI
import StudyCore
import StudyData
import SwiftUI

// Entry points for the review screen (developer mode only): two buttons, the drawing overlay and a modifier
// that presents overlay and form. The buttons hide themselves when the developer mode is off.

/// Toolbar button "Bereich als Fehler markieren" (starts drawing an area on the page).
struct ReportToolbarButton: View {
    @Environment(AIService.self) private var ai
    let action: () -> Void

    var body: some View {
        if ai.settings.developerModeEnabled {
            Button("Bereich als Fehler markieren", systemImage: "rectangle.dashed.badge.record", action: action)
                .accessibilityIdentifier("reportAreaButton")
        }
    }
}

/// Button "Fehler melden" for the bar of the selected line.
struct ReportLineButton: View {
    @Environment(AIService.self) private var ai
    let action: () -> Void

    var body: some View {
        if ai.settings.developerModeEnabled {
            Button("Fehler melden", systemImage: "exclamationmark.bubble", action: action)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reportErrorButton")
        }
    }
}

/// State of the report flow on a page: idle, drawing an area, or the form open.
struct ReportFlow: Equatable {
    struct Form: Identifiable, Equatable {
        let id = UUID()
        var lineID: UUID?
        var rect: NormalizedRect?
    }

    enum Phase: Equatable {
        case idle
        case drawing
        case form(Form)
    }

    var phase: Phase = .idle

    var isDrawing: Bool { phase == .drawing }

    /// Opens the form for the selected line.
    mutating func reportLine(_ id: UUID) { phase = .form(Form(lineID: id, rect: nil)) }

    /// Starts drawing an area on the page.
    mutating func startDrawing() { phase = .drawing }

    mutating func finishDrawing(_ rect: NormalizedRect) { phase = .form(Form(lineID: nil, rect: rect)) }

    mutating func cancel() { phase = .idle }

    var form: Form? {
        if case .form(let form) = phase { form } else { nil }
    }
}

extension View {
    /// Shows the area overlay while `flow` is drawing and the report form when it has a form.
    /// `pageImage` is the image the user draws on (the one the review shows).
    func reportFlow(
        _ flow: Binding<ReportFlow>, source: Source, batch: ImportBatch, lines: [RecognizedLine], pageImage: UIImage?
    ) -> some View {
        modifier(ReportFlowModifier(flow: flow, source: source, batch: batch, lines: lines, pageImage: pageImage))
    }
}

private struct ReportFlowModifier: ViewModifier {
    @Binding var flow: ReportFlow
    let source: Source
    let batch: ImportBatch
    let lines: [RecognizedLine]
    let pageImage: UIImage?

    func body(content: Content) -> some View {
        content
            .overlay {
                if flow.isDrawing, let pageImage {
                    ReportAreaOverlay(
                        image: pageImage, lines: lines,
                        onSelect: { flow.finishDrawing($0) }, onCancel: { flow.cancel() })
                }
            }
            .sheet(item: Binding(
                get: { flow.form },
                set: { if $0 == nil { flow.cancel() } })
            ) { form in
                ReportErrorSheet(
                    source: source, batch: batch, lines: lines, selectedLineID: form.lineID, drawnRect: form.rect)
            }
    }
}

/// Covers the page with its image; the user drags a rectangle around the place of the error.
/// The result is a `NormalizedRect` (fractions of the page, origin top-left, like `PageImageView`).
struct ReportAreaOverlay: View {
    let image: UIImage
    var lines: [RecognizedLine] = []
    let onSelect: (NormalizedRect) -> Void
    let onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fitFrame(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(.systemBackground)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .accessibilityHidden(true)
                ForEach(lines) { line in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
                        .frame(width: max(line.rect.width * fit.width, 4), height: max(line.rect.height * fit.height, 4))
                        .offset(x: fit.minX + line.rect.x * fit.width, y: fit.minY + line.rect.y * fit.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let rect = dragRect {
                    Rectangle()
                        .fill(Color.red.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 2))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .local)
                            .onChanged { value in
                                start = value.startLocation
                                current = value.location
                            }
                            .onEnded { value in
                                defer { start = nil; current = nil }
                                if let rect = Self.normalizedRect(from: value.startLocation, to: value.location, fit: fit) {
                                    onSelect(rect)
                                }
                            }
                    )
                    .accessibilityLabel("Seite, Bereich mit dem Finger aufziehen")
                    .accessibilityIdentifier("reportAreaCanvas")
            }
            .overlay(alignment: .top) { banner }
        }
        .accessibilityIdentifier("reportAreaOverlay")
    }

    private var banner: some View {
        HStack {
            Text("Ziehe einen Rahmen um die Stelle des Fehlers.")
                .font(.footnote)
            Spacer(minLength: 8)
            Button("Abbrechen", action: onCancel)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reportAreaCancelButton")
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private var dragRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    // MARK: Geometry (static for tests)

    /// The frame the image takes when fitted into `size` and centered.
    static func fitFrame(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    /// The dragged rectangle as page fractions, clamped to the page; nil when it is (almost) empty or outside.
    static func normalizedRect(from a: CGPoint, to b: CGPoint, fit: CGRect, minimumFraction: Double = 0.005) -> NormalizedRect? {
        guard fit.width > 0, fit.height > 0 else { return nil }
        func fraction(_ value: CGFloat, origin: CGFloat, length: CGFloat) -> Double {
            Double(min(max((value - origin) / length, 0), 1))
        }
        let x0 = fraction(min(a.x, b.x), origin: fit.minX, length: fit.width)
        let x1 = fraction(max(a.x, b.x), origin: fit.minX, length: fit.width)
        let y0 = fraction(min(a.y, b.y), origin: fit.minY, length: fit.height)
        let y1 = fraction(max(a.y, b.y), origin: fit.minY, length: fit.height)
        guard x1 - x0 >= minimumFraction, y1 - y0 >= minimumFraction else { return nil }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
