import SwiftUI

/// Japanese with readings printed above the kanji. SwiftUI's Text has no ruby
/// support, so each word is a small two-row stack and the words are wrapped
/// like text.
///
/// That also rules out SwiftUI's text selection, which stops at the edge of
/// one Text and never says what was selected. Selection is done here instead:
/// drag across characters, double-click a word, triple-click the line. What
/// to do with the selected text is up to `selectionActions` on a container.
struct FuriganaText: View {
    let tokens: [RubyToken]
    let fontSize: CGFloat
    var showReadings = true
    /// Character positions in the joined token bases.
    @Binding var selection: Range<Int>?

    /// Where the drag in progress started.
    @State private var anchor: Int?

    var body: some View {
        FlowLayout(lineSpacing: fontSize * 0.15) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                VStack(spacing: 0) {
                    if showReadings {
                        // A blank reading still takes its row, so every word
                        // has the same height and the base text shares one
                        // baseline.
                        Text(token.reading ?? " ")
                            .font(.system(size: fontSize * 0.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(token.base)
                        .font(.system(size: fontSize))
                        .anchorPreference(key: BaseBounds.self, value: .bounds) { [index: $0] }
                }
                .fixedSize()
                .layoutValue(key: GluesToPrevious.self, value: token.gluesToPrevious)
            }
        }
        .backgroundPreferenceValue(BaseBounds.self) { anchors in
            GeometryReader { proxy in
                if let selection {
                    let map = map(anchors, in: proxy)
                    let rects = map.rects(for: selection)
                    Path { path in path.addRects(rects) }
                        .fill(Color(nsColor: .selectedTextBackgroundColor))
                        .anchorPreference(key: SelectedText.Key.self, value: .rect(actionsTarget(rects))) {
                            SelectedText(text: map.text(in: selection), bounds: $0)
                        }
                }
            }
        }
        .overlayPreferenceValue(BaseBounds.self) { anchors in
            GeometryReader { proxy in
                let map = map(anchors, in: proxy)
                PointerTracker(
                    onDown: { point, clicks in pointerDown(at: point, clicks: clicks, map: map) },
                    onDrag: { point in pointerDragged(to: point, map: map) },
                    onResign: {
                        anchor = nil
                        if selection != nil { selection = nil }
                    }
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tokens.map(\.base).joined())
    }

    /// What the actions should keep clear of: the first selected line, with
    /// the readings over it.
    private func actionsTarget(_ rects: [CGRect]) -> CGRect {
        guard var rect = rects.first else { return .zero }
        if showReadings {
            let readings = fontSize * 0.6
            rect.origin.y -= readings
            rect.size.height += readings
        }
        return rect
    }

    private func map(_ anchors: [Int: Anchor<CGRect>], in proxy: GeometryProxy) -> RubySelectionMap {
        RubySelectionMap(tokens: tokens, frames: anchors.mapValues { proxy[$0] }, fontSize: fontSize)
    }

    private func pointerDown(at point: CGPoint, clicks: Int, map: RubySelectionMap) {
        switch clicks {
        case 1:
            // Also what dismisses a selection, in this caption or another.
            anchor = map.position(at: point)
            selection = nil
        case 2:
            anchor = nil
            selection = map.wordRange(at: point)
        default:
            anchor = nil
            selection = 0..<tokens.reduce(0) { $0 + $1.base.count }
        }
    }

    private func pointerDragged(to point: CGPoint, map: RubySelectionMap) {
        guard let anchor, let position = map.position(at: point) else { return }
        selection = anchor == position ? nil : min(anchor, position)..<max(anchor, position)
    }

}

/// The selection of a FuriganaText or a SelectableText somewhere below, for
/// `selectionActions`.
struct SelectedText {
    let text: String
    let bounds: Anchor<CGRect>

    struct Key: PreferenceKey {
        static let defaultValue: SelectedText? = nil

        static func reduce(value: inout SelectedText?, nextValue: () -> SelectedText?) {
            value = value ?? nextValue()
        }
    }
}

extension View {
    /// Floats a Jisho button over the text selected in any FuriganaText inside
    /// this view, and a Grammar button beside it when there is `onGrammar`;
    /// `canAskGrammar` greys it out while a question can't be asked. It belongs to the container and not to the text because it
    /// reaches outside its caption, where a row of a lazy stack is neither
    /// clickable nor safe from being drawn over by the next row.
    func selectionActions(
        lookUpHelp: @escaping (String) -> String = { "Look up \($0) on jisho.org" },
        onLookUp: @escaping (String) -> Void,
        canAskGrammar: Bool = true,
        onGrammar: ((String) -> Void)? = nil
    ) -> some View {
        overlayPreferenceValue(SelectedText.Key.self) { selected in
            GeometryReader { proxy in
                if let selected {
                    let rect = proxy[selected.bounds]
                    // Nothing to point at once the selection is scrolled away.
                    if rect.maxY > 0, rect.minY < proxy.size.height {
                        Color.clear.overlay(alignment: .topLeading) {
                            SelectionActions(
                                text: selected.text, help: lookUpHelp(selected.text), onLookUp: onLookUp,
                                canAskGrammar: canAskGrammar, onGrammar: onGrammar
                            )
                                .fixedSize()
                                .alignmentGuide(.leading) { size in
                                    // Centred on the selection, but not past either edge.
                                    min(max(size.width / 2 - rect.midX, size.width - proxy.size.width), 0)
                                }
                                .alignmentGuide(.top) { size in
                                    // Above the text, or below it at the top edge.
                                    let above = rect.minY - 4 - size.height
                                    return above >= 0 ? -above : -(rect.maxY + 4)
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct SelectionActions: View {
    let text: String
    let help: String
    let onLookUp: (String) -> Void
    let canAskGrammar: Bool
    let onGrammar: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onLookUp(text)
            } label: {
                Label("Jisho", systemImage: "character.book.closed")
            }
            .help(help)
            if let onGrammar {
                Divider()
                    .frame(height: 12)
                Button {
                    onGrammar(text)
                } label: {
                    Label("Grammar", systemImage: "text.book.closed")
                }
                .disabled(!canAskGrammar)
                .opacity(canAskGrammar ? 1 : 0.4)
                .help(canAskGrammar ? "Ask about the grammar of \(text)" : "Wait for the analysis or answer to finish")
            }
            Divider()
                .frame(height: 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy")
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
    }
}

/// Mouse handling for the selection. A SwiftUI gesture would do, except that
/// the window is movable by its background and a drag over the text has to
/// select rather than move the window; only a view can turn that down.
private struct PointerTracker: NSViewRepresentable {
    let onDown: (CGPoint, Int) -> Void
    let onDrag: (CGPoint) -> Void
    /// Something else in the window was clicked: other text, a text field.
    let onResign: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onDown = onDown
        view.onDrag = onDrag
        view.onResign = onResign
    }

    final class TrackerView: NSView {
        var onDown: (CGPoint, Int) -> Void = { _, _ in }
        var onDrag: (CGPoint) -> Void = { _ in }
        var onResign: () -> Void = {}

        // Top-left origin, as in SwiftUI.
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        // Captions float over another app, which is usually the active one:
        // the click that selects must not be spent on activating the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // The text clicked last is the first responder, as a text view would
        // be, and the one before it hears that its selection is over: a
        // SelectableText's, or another caption's.
        override var acceptsFirstResponder: Bool { true }

        override func resignFirstResponder() -> Bool {
            onResign()
            return true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onDown(convert(event.locationInWindow, from: nil), event.clickCount)
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag(convert(event.locationInWindow, from: nil))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .iBeam)
        }
    }
}

/// The frame of each token's base text, by token index.
private struct BaseBounds: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct GluesToPrevious: LayoutValueKey {
    static let defaultValue = false
}

/// Left-to-right wrapping. A subview marked GluesToPrevious stays on the same
/// line as the one before it, which keeps 。 and 、 off the start of a line.
private struct FlowLayout: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Runs of subviews that must not be split across lines.
        var groups: [Range<Int>] = []
        for index in subviews.indices {
            if subviews[index][GluesToPrevious.self], let last = groups.popLast() {
                groups.append(last.lowerBound..<index + 1)
            } else {
                groups.append(index..<index + 1)
            }
        }

        var origins = [CGPoint](repeating: .zero, count: subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for group in groups {
            let groupWidth = group.reduce(0) { $0 + sizes[$1].width }
            if x > 0, x + groupWidth > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            for index in group {
                origins[index] = CGPoint(x: x, y: y)
                x += sizes[index].width
                lineHeight = max(lineHeight, sizes[index].height)
            }
            usedWidth = max(usedWidth, x)
        }
        return (origins, CGSize(width: usedWidth, height: y + lineHeight))
    }
}
