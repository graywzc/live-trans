import AVKit
import SwiftUI

/// The video on top with its own controls, its captions below kept on
/// the sentence being spoken; a tap on a caption plays the sentence
/// again, the button at its end explains it in a sheet, a long press on a
/// word offers jisho.org, Apple's dictionary, the LLM's entry and the
/// clipboard. Where the video was left is kept for the next opening.
struct PlayerView: View {
    let bundle: VideoBundle

    @Environment(BundleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 20.0
    @State private var model: PlaybackModel?
    @State private var sheet = AnalysisSheetModel()

    var body: some View {
        Group {
            if let model {
                PlayerScreen(
                    model: model, fontSize: fontSize, showFurigana: showFurigana, onAnalyze: sheet.open,
                    onWord: word
                )
            } else {
                Color.clear
            }
        }
        .navigationTitle(bundle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if model == nil {
                model = PlaybackModel(bundle: bundle, video: store.videoURL(for: bundle.id))
            }
            model?.start()
        }
        .onDisappear {
            model?.stop()
            sheet.end()
        }
        .sheet(item: $sheet.presenting) { presenting in
            switch presenting {
            case .thread:
                AnalysisSheet(model: sheet)
            case .jisho(let word):
                JishoSheet(word: word)
            case .dictionary(let word):
                DictionarySheet(term: word)
            }
        }
        .onChange(of: scenePhase) {
            // Put away, the app may not come back: where the video is goes
            // on record now.
            if scenePhase != .active { model?.remember() }
        }
    }

    /// What the word menu's items do: each a sheet in the one slot.
    private func word(_ action: WordAction, _ word: String, in caption: Caption) {
        switch action {
        case .jisho: sheet.showJisho(word)
        case .dictionary: sheet.showDictionary(word)
        case .grammar: sheet.lookUp(word, in: caption)
        }
    }
}

/// The screen once the model is there.
struct PlayerScreen: View {
    let model: PlaybackModel
    let fontSize: Double
    let showFurigana: Bool
    let onAnalyze: (Caption) -> Void
    var onWord: ((WordAction, String, Caption) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
            CaptionScroll(
                captions: model.captions, playingID: model.playingID, lull: model.lull,
                fontSize: fontSize, showFurigana: showFurigana, onTap: model.replay, onAnalyze: onAnalyze,
                onWord: onWord
            )
        }
    }
}
