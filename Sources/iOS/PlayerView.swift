import AVKit
import SwiftUI

/// The video on top with its own controls, its captions below kept on
/// the sentence being spoken; a tap on a caption plays the sentence
/// again. Where the video was left is kept for the next opening.
struct PlayerView: View {
    let bundle: VideoBundle

    @Environment(BundleStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 20.0
    @State private var model: PlaybackModel?

    var body: some View {
        Group {
            if let model {
                PlayerScreen(model: model, fontSize: fontSize, showFurigana: showFurigana)
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
        .onDisappear { model?.stop() }
        .onChange(of: scenePhase) {
            // Put away, the app may not come back: where the video is goes
            // on record now.
            if scenePhase != .active { model?.remember() }
        }
    }
}

/// The screen once the model is there.
struct PlayerScreen: View {
    let model: PlaybackModel
    let fontSize: Double
    let showFurigana: Bool

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
            CaptionScroll(
                captions: model.captions, playingID: model.playingID, lull: model.lull,
                fontSize: fontSize, showFurigana: showFurigana, onTap: model.replay
            )
        }
    }
}
