import SwiftUI

/// Text that is selected the way SwiftUI's `textSelection(.enabled)` text is,
/// and that says what was selected, which SwiftUI's never does: the selection
/// is offered to `selectionActions` on a container like a FuriganaText's.
///
/// An AppKit text view underneath. Whichever text was clicked last is the
/// window's first responder, and one that stops being it drops its selection:
/// there is one selection in the window, and one place for the actions to be.
struct SelectableText: View {
    let text: NSAttributedString
    /// A plain click on the text: not a drag, not a double-click, and not the
    /// click that dismisses a selection.
    var onClick: (() -> Void)?

    @State private var selected: Selected?

    fileprivate struct Selected: Equatable {
        let text: String
        /// The first selected line, in the text's coordinates.
        let rect: CGRect
    }

    init(
        _ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
        onClick: (() -> Void)? = nil
    ) {
        text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
        self.onClick = onClick
    }

    /// Markdown's bold, italics and code, which an AppKit text view would
    /// otherwise carry as attributes it doesn't draw.
    init(_ attributed: AttributedString, size: CGFloat, color: NSColor = .white, lineSpacing: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let text = NSMutableAttributedString()
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let weight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : .regular
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            text.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]))
        }
        self.text = text
    }

    var body: some View {
        TextBox(text: text, onClick: onClick) { selected = $0 }
            .anchorPreference(key: SelectedText.Key.self, value: .rect(selected?.rect ?? .zero)) { bounds in
                selected.map { SelectedText(text: $0.text, bounds: bounds) }
            }
    }
}

private struct TextBox: NSViewRepresentable {
    let text: NSAttributedString
    let onClick: (() -> Void)?
    let onSelect: (SelectableText.Selected?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BoxView {
        // TextKit 1, put together by hand: asking a text view for its layout
        // manager later would make it switch to TextKit 1 mid-life.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let view = BoxView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        // SwiftUI sizes it, from sizeThatFits.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: BoxView, context: Context) {
        context.coordinator.onSelect = onSelect
        view.click.onClick = onClick ?? {}
        // Not compared with what the view holds: that has fonts of its own
        // choosing over the kanji and would never be equal.
        guard context.coordinator.text != text else { return }
        context.coordinator.text = text
        // New text takes the selection with it, and says so from inside this
        // update, where SwiftUI's state can't be written.
        context.coordinator.isUpdating = true
        view.textStorage?.setAttributedString(text)
        context.coordinator.isUpdating = false
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoxView, context: Context) -> CGSize? {
        // Without a width, all on one line. Never narrower than a character
        // or two, so that no width doesn't mean a line per character.
        let width = max(proposal.width ?? .greatestFiniteMagnitude, 20)
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (SelectableText.Selected?) -> Void = { _ in }
        var text: NSAttributedString?
        var isUpdating = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? BoxView else { return }
            if isUpdating {
                // The selection as it is by then, not as it is now: one made in
                // between would otherwise be reported and then taken back.
                DispatchQueue.main.async { [onSelect, weak view] in onSelect(view?.selected) }
            } else {
                onSelect(view.selected)
            }
        }
    }

    final class BoxView: NSTextView {
        // The window is movable by its background, which a view that draws
        // none counts as; a drag over the text has to select.
        override var mouseDownCanMoveWindow: Bool { false }

        // Captions float over another app, which is usually the active one:
        // the click that selects must not be spent on activating the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        let click = SingleClick()

        // The text view tracks the mouse itself until it is released, so the
        // click is known only afterwards: one that left no selection and
        // dismissed none.
        override func mouseDown(with event: NSEvent) {
            let hadSelection = selectedRange().length > 0
            click.mouseDown(with: event)
            super.mouseDown(with: event)
            if !hadSelection, selectedRange().length == 0 {
                click.mouseUp(with: event)
            }
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }

        var selected: SelectableText.Selected? {
            let range = selectedRange()
            guard range.length > 0, let layoutManager, let textContainer else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var firstLine = CGRect.zero
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: textContainer
            ) { rect, stop in
                firstLine = rect
                stop.pointee = true
            }
            return SelectableText.Selected(text: (string as NSString).substring(with: range), rect: firstLine)
        }
    }
}
