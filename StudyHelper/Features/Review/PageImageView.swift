import StudyCore
import SwiftUI

/// The page image with tappable line overlays and drawn highlights; pinch or buttons to zoom.
/// All rects are page fractions with the origin top-left (`NormalizedRect`).
struct PageImageView: View {
    let image: UIImage
    let lines: [RecognizedLine]
    let highlights: [RecognizedHighlight]
    @Binding var selectedLineID: UUID?
    let onlyOpen: Bool
    /// An area of the page to point at (the source of a topic entry); the view scrolls to it.
    var markedRect: NormalizedRect?

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var position = ScrollPosition()
    /// Set when the selection was made by tapping here; the view then does not move itself.
    @State private var tappedHere: UUID?

    private static let maxZoom: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let fit = fitSize(in: geo.size)
            let content = CGSize(width: fit.width * zoom, height: fit.height * zoom)
            ScrollView([.horizontal, .vertical]) {
                canvas(size: content)
                    .frame(width: content.width, height: content.height)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .scrollPosition($position)
            .background(Color(.secondarySystemBackground))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(max(baseZoom * value.magnification, 1), Self.maxZoom) }
                    .onEnded { _ in baseZoom = zoom }
            )
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onChange(of: selectedLineID) { _, id in
                guard let id, let line = lines.first(where: { $0.id == id }) else { return }
                if tappedHere == id { tappedHere = nil; return }
                focus(on: line.rect, viewport: geo.size)
            }
            .onChange(of: markedRect) { _, rect in
                if let rect { focus(on: rect, viewport: geo.size) }
            }
            .task(id: image.size.width) {
                // Coming back to a page (or switching from the text view) with a line selected.
                if let id = selectedLineID, let line = lines.first(where: { $0.id == id }) {
                    focus(on: line.rect, viewport: geo.size)
                } else if let markedRect {
                    focus(on: markedRect, viewport: geo.size)
                }
            }
        }
        .accessibilityIdentifier("pageImage")
    }

    // MARK: Geometry

    private func fitSize(in viewport: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.size.width, viewport.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Zooms in (if needed) and scrolls so that the area is in the middle of the viewport.
    private func focus(on area: NormalizedRect, viewport: CGSize) {
        let fit = fitSize(in: viewport)
        // Zoom in so that the line fills most of the width, but never zoom out and not beyond 3×.
        let lineWidth = max(area.width * fit.width, 1)
        let lineZoom = min(viewport.width * 0.9 / lineWidth, 3)
        let target = max(zoom, lineZoom)
        if abs(target - zoom) > 0.01 {
            withAnimation { zoom = target }
            baseZoom = target
        }
        let content = CGSize(width: fit.width * target, height: fit.height * target)
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            let lineLeft = area.minX * content.width
            let lineW = area.width * content.width
            // A line wider than the viewport is shown from its start, otherwise it is centered.
            let wantedX = lineW > viewport.width - 24 ? lineLeft - 12 : area.midX * content.width - viewport.width / 2
            let x = min(max(wantedX, 0), max(content.width - viewport.width, 0))
            let y = min(max(area.midY * content.height - viewport.height / 2, 0), max(content.height - viewport.height, 0))
            withAnimation { position.scrollTo(x: x, y: y) }
        }
    }

    // MARK: Canvas

    private func canvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .accessibilityLabel("Originalbild der Seite")
            ForEach(highlights) { highlight in
                HighlightMark(highlight: highlight, size: size)
            }
            if let markedRect {
                SourceMark(rect: markedRect, size: size)
            }
            ForEach(lines) { line in
                LineOverlay(
                    line: line, highlights: highlights, size: size,
                    isSelected: line.id == selectedLineID, dimmed: onlyOpen && !line.needsReview
                ) {
                    tappedHere = line.id
                    selectedLineID = (selectedLineID == line.id) ? nil : line.id
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button("Verkleinern", systemImage: "minus") { setZoom(zoom / 1.5) }
                .disabled(zoom <= 1.01)
                .accessibilityIdentifier("zoomOutButton")
            Divider().frame(height: 22)
            Button("Ganze Seite", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { setZoom(1) }
                .disabled(zoom <= 1.01)
                .accessibilityIdentifier("zoomFitButton")
            Divider().frame(height: 22)
            Button("Vergrößern", systemImage: "plus") { setZoom(zoom * 1.5) }
                .disabled(zoom >= Self.maxZoom - 0.01)
                .accessibilityIdentifier("zoomInButton")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation {
            zoom = min(max(value, 1), Self.maxZoom)
            baseZoom = zoom
        }
    }
}

private struct LineOverlay: View {
    let line: RecognizedLine
    let highlights: [RecognizedHighlight]
    let size: CGSize
    let isSelected: Bool
    let dimmed: Bool
    let onTap: () -> Void

    private var tint: Color? {
        switch line.displayStatus {
        case .confident: nil
        case .uncertain: .orange
        case .illegible: .red
        case .corrected: .green
        }
    }

    var body: some View {
        let frame = CGRect(
            x: line.rect.x * size.width, y: line.rect.y * size.height,
            width: max(line.rect.width * size.width, 10), height: max(line.rect.height * size.height, 10))
        let fill: Color = isSelected ? Color.accentColor.opacity(0.18) : (dimmed ? .clear : (tint?.opacity(0.28) ?? .clear))
        let stroke: Color = isSelected ? Color.accentColor : (dimmed ? .clear : (tint?.opacity(0.9) ?? Color.blue.opacity(0.22)))
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(stroke, lineWidth: isSelected ? 3 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spokenLabel(highlights: highlights))
        .accessibilityValue(isSelected ? "ausgewählt" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("imageLine-\(line.order)")
    }
}

/// A highlight drawn over the page: marker fill, underline, circle, box.
private struct HighlightMark: View {
    let highlight: RecognizedHighlight
    let size: CGSize

    var body: some View {
        let r = CGRect(
            x: highlight.rect.x * size.width, y: highlight.rect.y * size.height,
            width: highlight.rect.width * size.width, height: highlight.rect.height * size.height)
        let color = highlight.displayColor
        Group {
            switch highlight.kind {
            case .highlighter:
                Rectangle().fill(color.opacity(0.6)).blendMode(.multiply)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            case .underline:
                Rectangle().fill(color).frame(width: r.width, height: 3).offset(x: r.minX, y: r.maxY - 3)
            case .doubleUnderline:
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(color).frame(width: r.width, height: 3).offset(x: 0, y: r.height - 3)
                    Rectangle().fill(color).frame(width: r.width, height: 3).offset(x: 0, y: r.height - 8)
                }
                .frame(width: r.width, height: r.height, alignment: .topLeading)
                .offset(x: r.minX, y: r.minY)
            case .circled:
                Ellipse().strokeBorder(color, lineWidth: 3)
                    .frame(width: r.width * 1.12 + 8, height: r.height * 1.4 + 4)
                    .offset(x: r.minX - r.width * 0.06 - 4, y: r.minY - r.height * 0.2 - 2)
            case .boxed:
                Rectangle().strokeBorder(color, lineWidth: 2.5)
                    .frame(width: r.width + 4, height: r.height + 2).offset(x: r.minX - 2, y: r.minY - 1)
            case .bold, .coloredPen, .uppercase:
                // No geometric mark in the original: a dashed underline shows the emphasized area.
                Path { path in
                    path.move(to: CGPoint(x: r.minX, y: r.maxY))
                    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: [5, 3]))
                .frame(width: size.width, height: size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The area an entry of a topic points at, drawn over the page image.
private struct SourceMark: View {
    let rect: NormalizedRect
    let size: CGSize

    var body: some View {
        let frame = CGRect(
            x: rect.x * size.width, y: rect.y * size.height,
            width: max(rect.width * size.width, 14), height: max(rect.height * size.height, 14))
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3))
            .padding(-4)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Markierte Stelle im Original")
            .accessibilityValue("ausgewählt")
            .accessibilityIdentifier("sourceMark")
    }
}
