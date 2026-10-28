import SwiftUI

/// The sheet the button at a caption's end opens: the sentences explained,
/// by the shared AnalysisView, at half height so that the video plays on
/// and the rows stay tappable, or pulled up to full. The thread lasts while
/// the video is open and goes with it: nothing of it is kept.
@MainActor
@Observable
final class AnalysisSheetModel {
    let analyzer: SentenceAnalyzer
    var isPresented = false

    /// With an analyzer of its own unless given one (the tests' scripted
    /// one); made here, on the main actor, not as a default argument.
    init(analyzer: SentenceAnalyzer? = nil) {
        self.analyzer = analyzer ?? SentenceAnalyzer()
    }

    /// The caption's sentence explained in the sheet, which opens if it is
    /// not up; a sentence asked about before is turned to again.
    func open(_ caption: Caption) {
        analyzer.analyze(caption)
        isPresented = true
    }

    /// The analysis the sheet is turned to: the one last asked for.
    var shown: Analysis? {
        guard let revealed = analyzer.revealed else { return nil }
        return analyzer.analyses.first { $0.id == revealed.id }
    }

    /// Leaving the video: the sheet goes, and the thread with it.
    func end() {
        isPresented = false
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
