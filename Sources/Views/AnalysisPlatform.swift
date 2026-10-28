import SwiftUI

/// What the shared analysis views (`AnalysisView`, `LookupView`) take from
/// the Mac: the side panel's colours, white text on its dark background; the
/// Japanese with readings, which can be selected and looked up; and the way
/// to Settings. The phone gives its own in `Sources/iOS/AnalysisPlatform`.
enum Palette {
    static let text: Color = .white
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let gray = Color(nsColor: .systemGray)
    static let lightGray = Color(nsColor: .lightGray)
    static let orange = Color(nsColor: .systemOrange)
    /// Behind a dictionary entry, to set it off from the explanations.
    static let card = Color.white.opacity(0.07)
}

/// The analyzed sentence with its readings: a FuriganaText, with a
/// selection of its own for the panel's Jisho and Grammar buttons.
struct AnalysisRuby: View {
    let tokens: [RubyToken]
    let fontSize: CGFloat

    /// A range of this sentence.
    @State private var selection: Range<Int>?

    var body: some View {
        FuriganaText(tokens: tokens, fontSize: fontSize, selection: $selection)
    }
}

/// Opens Settings, where the LLM server is entered.
struct SettingsButton: View {
    var body: some View {
        SettingsLink {
            Text("Open Settings")
        }
    }
}
