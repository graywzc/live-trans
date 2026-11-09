import SwiftUI

/// Whether the list follows the video or stays where a finger put it.
struct FollowState: Equatable {
    private(set) var isFollowing = true

    /// The list moved: by a finger, which takes it from the video; moved
    /// by the app, it goes on following.
    mutating func scrolled(byUser: Bool) {
        if byUser { isFollowing = false }
    }

    mutating func returned() {
        isFollowing = true
    }

    /// Whether the row the video has moved to should be brought into view.
    func shouldShow(_ playingID: Int?) -> Bool {
        isFollowing && playingID != nil
    }
}

/// The captions under the video, kept on the sentence being spoken: the
/// lit row is brought to the middle as the video moves on. Scrolled by
/// hand the list stays where it was put, and a pill over its foot takes
/// it back. Between sentences a line marks where the video is, in the gap
/// under the last one spoken so that the rows do not shift.
struct CaptionScroll: View {
    let captions: [Caption]
    let playingID: Int?
    let lull: Lull?
    let fontSize: Double
    let showFurigana: Bool
    /// The recognizer picked for each caption that has one, or the text
    /// typed in place of theirs.
    var picks: [Int: Pick] = [:]
    /// The typed texts as captions, by the caption's id.
    var typed: [Int: Caption] = [:]
    /// A tap on a row: plays the sentence again.
    let onTap: (Caption) -> Void
    /// A version's name tapped in a row: picks it, or with nil takes the
    /// pick back.
    var onPick: ((String?, Caption) -> Void)? = nil
    /// Text typed from a row's pencil: the caption from now on; blank, the
    /// typed text is dropped. None, and there are no pencils.
    var onType: ((String, Caption) -> Void)? = nil
    /// The button at a row's end; none, and there is no button.
    var onAnalyze: ((Caption) -> Void)? = nil
    /// The word menu's items, for the word pressed in the caption; none,
    /// and a long press does nothing.
    var onWord: ((WordAction, String, Caption) -> Void)? = nil

    @State private var follow = FollowState()
    @Environment(\.scenePhase) private var scenePhase

    private static let spacing: CGFloat = 18
    /// Further than this the list jumps: gliding there would lay out every
    /// row on the way, and freeze the screen after a while away.
    private static let glideRows = 4

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(captions) { caption in
                        // Ahead of the first sentence there is no gap to
                        // draw the line in, so it takes a place of its own.
                        if let lull, !lull.isAfter, lull.captionID == caption.id {
                            PhoneSplitter(seconds: lull.seconds, fontSize: fontSize)
                        }
                        PhoneCaptionRow(
                            caption: caption, fontSize: fontSize, showFurigana: showFurigana,
                            isCurrent: caption.id == playingID, picked: picks[caption.id]?.name,
                            typed: typed[caption.id], onTap: { onTap(caption) },
                            onPick: onPick.map { pick in { pick($0, caption) } },
                            onType: onType.map { type in { type($0, caption) } },
                            onAnalyze: onAnalyze.map { analyze in
                                { analyze(typed[caption.id] ?? caption.heard(by: picks[caption.id]?.name)) }
                            },
                            onWord: onWord
                        )
                        .equatable()
                        .id(caption.id)
                        .overlay(alignment: .bottom) {
                            if let lull, lull.isAfter, lull.captionID == caption.id {
                                PhoneSplitter(seconds: lull.seconds, fontSize: fontSize)
                                    .frame(height: Self.spacing)
                                    .offset(y: Self.spacing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onScrollPhaseChange { _, phase in
                follow.scrolled(byUser: phase == .interacting)
            }
            .overlay(alignment: .bottom) {
                if !follow.isFollowing, playingID != nil {
                    ReturnPill {
                        follow.returned()
                        if let playingID { proxy.scrollTo(playingID, anchor: .center) }
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: follow.isFollowing)
            .onChange(of: playingID) { old, new in
                // Put away, the list is seen to when it comes back.
                guard scenePhase == .active, follow.shouldShow(new), let new else { return }
                show(new, from: old, in: proxy)
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active, follow.shouldShow(playingID), let playingID {
                    proxy.scrollTo(playingID, anchor: .center)
                }
            }
            .onAppear {
                if let playingID { proxy.scrollTo(playingID, anchor: .center) }
            }
        }
    }

    private func show(_ id: Int, from old: Int?, in proxy: ScrollViewProxy) {
        guard let old, abs(id - old) <= Self.glideRows else {
            proxy.scrollTo(id, anchor: .center)
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// Takes the list back to the sentence being spoken, and follows it again.
private struct ReturnPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Now playing", systemImage: "scope")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Returns to what is being said, and follows it")
    }
}

/// Marks where the video is between two sentences: a line across the
/// list, with the time at its right end.
struct PhoneSplitter: View {
    let seconds: Int
    let fontSize: Double

    static let color = Color.orange

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Self.color)
                .frame(height: 1.5)
            Text(PhoneCaptionRow.timestamp(Double(seconds)))
                .font(.system(size: fontSize * 0.55).monospacedDigit())
                .foregroundStyle(Self.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video is here")
        .accessibilityValue(PhoneCaptionRow.timestamp(Double(seconds)))
    }
}
