import SwiftUI

/// The Mac's `SelectableText` on the phone: text a long press selects and
/// copies, as SwiftUI's `textSelection(.enabled)` has it, with the Mac's
/// initializers so that the shared analysis views read the same on both.
/// What was selected is not known here, so nothing floats over a selection;
/// the long press on a word is for later.
struct SelectableText: View {
    private let text: Text
    private let lineSpacing: CGFloat

    init(
        _ string: String, size: CGFloat, weight: Font.Weight = .regular, color: Color = Palette.text,
        onClick: (() -> Void)? = nil
    ) {
        text = Text(string)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
        lineSpacing = 0
    }

    /// Markdown's bold, italics and code, which Text draws as such.
    init(_ attributed: AttributedString, size: CGFloat, color: Color = Palette.text, lineSpacing: CGFloat = 0) {
        text = Text(attributed)
            .font(.system(size: size))
            .foregroundStyle(color)
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        text
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
    }
}

extension View {
    /// The Mac's Jisho and Grammar buttons over a selection, which the
    /// phone has no selection to put them over: the view as it is.
    func selectionActions(
        lookUpHelp: @escaping (String) -> String = { _ in "" },
        onLookUp: @escaping (String) -> Void,
        canAskGrammar: Bool = true,
        onGrammar: ((String) -> Void)? = nil
    ) -> some View {
        self
    }
}
