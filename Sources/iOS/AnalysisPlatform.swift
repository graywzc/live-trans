import SwiftUI

/// What the shared analysis views (`AnalysisView`, `LookupView`) take from
/// the phone: the system's colours, so the sheet reads in light and dark;
/// the Japanese with readings; and no way to Settings from the sheet, which
/// has a tab of its own. The Mac gives its own in `Views/AnalysisPlatform`.
enum Palette {
    static let text: Color = .primary
    static let secondary: Color = .secondary
    static let gray = Color(uiColor: .systemGray)
    static let lightGray: Color = .secondary
    static let orange: Color = .orange
    /// Behind a dictionary entry, to set it off from the explanations.
    static let card = Color(uiColor: .secondarySystemBackground)
}

/// The analyzed sentence with its readings, always shown here.
struct AnalysisRuby: View {
    let tokens: [RubyToken]
    let fontSize: CGFloat

    var body: some View {
        RubyText(tokens: tokens, fontSize: fontSize)
    }
}

/// Settings is a tab of its own: nothing to open from the sheet.
struct SettingsButton: View {
    var body: some View {
        EmptyView()
    }
}
