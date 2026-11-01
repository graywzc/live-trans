import AVKit
import SwiftUI

/// The video on top with its own controls, its captions below kept on
/// the sentence being spoken; a tap on a caption plays the sentence
/// again and stops at its end, the top bar's button pauses the video or
/// goes on from where it stopped, the button at a caption's end explains
/// it in a sheet, a long press on a word offers jisho.org, Apple's
/// dictionary, the LLM's entry and the clipboard. Where the video was
/// left is kept for the next opening, and until the screen is ready it
/// says how far it has got.
struct PlayerView: View {
    let bundle: VideoBundle

    @Environment(BundleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 20.0
    @AppStorage(AppSettings.bundleHost) private var hostText = ""
    @State private var model: PlaybackModel?
    @State private var sheet = AnalysisSheetModel()
    @State private var preparedLines = 0

    var body: some View {
        Group {
            if let model {
                PlayerScreen(
                    model: model, fontSize: fontSize, showFurigana: showFurigana, onAnalyze: sheet.open,
                    onWord: word
                )
            } else {
                OpeningProgress(done: preparedLines, total: bundle.lines.count)
            }
        }
        .navigationTitle(bundle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard model == nil else { return }
            let captions = await PlaybackModel.captions(of: bundle) { preparedLines = $0 }
            // Gone back meanwhile: nothing to play.
            guard !Task.isCancelled else { return }
            model = PlaybackModel(
                bundle: bundle, video: store.videoURL(for: bundle.id), captions: captions,
                timingsURL: PlaybackTimings.endpoint(host: AppSettings.hostURL(hostText))
            )
            model?.start()
        }
        .onAppear { model?.start() }
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
                .overlay {
                    if model.video != .ready {
                        VideoLoading(state: model.video)
                    }
                }
            CaptionScroll(
                captions: model.captions, playingID: model.playingID, lull: model.lull,
                fontSize: fontSize, showFurigana: showFurigana, onTap: model.replay, onAnalyze: onAnalyze,
                onWord: onWord
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isPlaying {
                    Button("Pause", systemImage: "pause.fill", action: model.pause)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Continue", systemImage: "play.fill", action: model.continuePlaying)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

/// What the screen shows while the captions are being made.
struct OpeningProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text("Preparing captions \(done) of \(total)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Over the video's place, until it is there.
private struct VideoLoading: View {
    let state: VideoState

    var body: some View {
        ZStack {
            Color.black
            if state == .failed {
                Label("The video can't be played", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.white)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading video")
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
