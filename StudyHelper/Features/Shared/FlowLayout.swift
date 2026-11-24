import SwiftUI

/// Places its subviews in rows and wraps to the next row when the width is used up (chips, word pickers).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(for: subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = rows(for: subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A text field that saves when editing ends (focus lost, return, leaving the screen), not on every key stroke.
struct CommitTextField: View {
    let title: String
    let value: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    /// Saves `text`; returns false if it was rejected (the field then shows `value` again).
    let onCommit: (String) -> Bool

    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let lineLimit {
                TextField(title, text: $text, axis: axis).lineLimit(lineLimit)
            } else {
                TextField(title, text: $text, axis: axis)
            }
        }
        .focused($focused)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onChange(of: value) { _, newValue in if !focused { text = newValue } }
        .onAppear {
            if !loaded { text = value; loaded = true }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard loaded, text != value else { return }
        if !onCommit(text) { text = value }
    }
}
