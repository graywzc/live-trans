import SwiftUI

/// The sheet the button at a caption's end opens: the sentences explained,
/// by the shared AnalysisView, at half height so that the video plays on
/// and the rows stay tappable, or pulled up to full. The thread lasts while
/// the video is open and goes with it: nothing of it is kept. The same
/// slot shows the word menu's sheets, jisho.org and Apple's dictionary,
/// one at a time: the thread is kept meanwhile and comes back at the next
/// press.
@MainActor
@Observable
final class AnalysisSheetModel {
    let analyzer: SentenceAnalyzer
    /// What the sheet shows, or nothing while it is down.
    var presenting: Presenting?

    enum Presenting: Equatable, Identifiable {
        case thread
        case jisho(String)
        case dictionary(String)

        var id: String {
            switch self {
            case .thread: "thread"
            case .jisho(let word): "jisho:\(word)"
            case .dictionary(let word): "dictionary:\(word)"
            }
        }
    }

    /// Whether the thread is up.
    var isPresented: Bool {
        get { presenting == .thread }
        set { presenting = newValue ? .thread : nil }
    }

    /// With an analyzer of its own unless given one (the tests' scripted
    /// one); made here, on the main actor, not as a default argument.
    init(analyzer: SentenceAnalyzer? = nil) {
        self.analyzer = analyzer ?? SentenceAnalyzer()
    }

    /// The caption's sentence explained in the sheet, which opens if it is
    /// not up; a sentence asked about before is turned to again.
    func open(_ caption: Caption) {
        analyzer.analyze(caption)
        presenting = .thread
    }

    /// A word of the caption looked up by the LLM, as said in the caption's
    /// sentence: its entry and grammar go at the end of the thread, which
    /// the sheet opens on.
    func lookUp(_ word: String, in caption: Caption) {
        analyzer.lookUp(word, in: caption.japanese)
        presenting = .thread
    }

    /// The word on jisho.org, or in Apple's dictionaries, in the sheet's
    /// place; the thread waits.
    func showJisho(_ word: String) {
        presenting = .jisho(word)
    }

    func showDictionary(_ word: String) {
        presenting = .dictionary(word)
    }

    /// The analysis the sheet is turned to: the one last asked for.
    var shown: Analysis? {
        guard let revealed = analyzer.revealed else { return nil }
        return analyzer.analyses.first { $0.id == revealed.id }
    }

    /// Leaving the video: the sheet goes, and the thread with it.
    func end() {
        presenting = nil
        analyzer.clear()
    }
}

struct AnalysisSheet: View {
    let model: AnalysisSheetModel

    var body: some View {
        AnalysisView()
            .environment(model.analyzer)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
    }
}
