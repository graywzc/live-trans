import SwiftUI

/// The captions, kept on what is being said: the end, where live captions
/// arrive, or the sentence a video captioned ahead has reached, whose later
/// captions are already below it. Between sentences a splitter marks where
/// the video is, and a gap long enough to hold a sentence that went
/// unheard shows one under the pointer; each has a button that hears the
/// gap again. Scrolled by hand the list stays where it
/// was put, and a pill over its foot takes it back.
struct CaptionList<Row: View>: View {
    let captions: [Caption]
    let partialText: String
    let fontSize: Double
    /// The caption the video is at, among ones fetched ahead of it. Nil when
    /// there are only live captions, which are followed at the end.
    let playingID: Int?
    /// Where the video is while none of them is being spoken.
    var lull: Lull? = nil
    /// Hears the gap the video is in again, when there is one to hear.
    var lullRehearing: (() -> Void)? = nil
    /// Hears the gap under a caption again, for the captions whose gap can
    /// be; nil for the others.
    var gapRehearing: (Caption) -> (() -> Void)? = { _ in nil }
    @ViewBuilder let row: (Caption) -> Row

    @State private var isFollowing = true
    @State private var onScreen = RowsOnScreen()

    private static var bottom: String { "bottom" }
    private static var spacing: CGFloat { 18 }

    private enum Target: Equatable {
        case caption(Int)
        case end
    }

    /// What the list is kept on, and the sentence it is for.
    private struct Place: Equatable {
        let playingID: Int?
        let target: Target
    }

    /// The last caption is followed at the end like a live one, so that what
    /// is being heard after it shows too.
    private var target: Target {
        if let playingID, playingID != captions.last?.id { .caption(playingID) } else { .end }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(captions) { caption in
                        // Ahead of the first sentence there is no gap to
                        // draw it in, so it takes a place of its own.
                        if let lull, !lull.isAfter, lull.captionID == caption.id {
                            PlayheadSplitter(seconds: lull.seconds, fontSize: fontSize, onRehear: lullRehearing)
                        }
                        row(caption)
                            // In the gap under the row, so that the list
                            // doesn't shift each time the talk pauses.
                            .overlay(alignment: .bottom) {
                                GapBelow(
                                    lull: lull.flatMap { $0.isAfter && $0.captionID == caption.id ? $0 : nil },
                                    fontSize: fontSize, onRehearLull: lullRehearing, onRehear: gapRehearing(caption)
                                )
                                .frame(height: Self.spacing)
                                .offset(y: Self.spacing)
                            }
                            .onAppear { onScreen.ids.insert(caption.id) }
                            .onDisappear { onScreen.ids.remove(caption.id) }
                    }
                    if !partialText.isEmpty {
                        Text(partialText)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.gray)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .background(ScrollWatcher { isFollowing = false })
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottom) {
                if !isFollowing, !captions.isEmpty {
                    ReturnPill(captions: captions, playingID: playingID, onScreen: onScreen) {
                        isFollowing = true
                        show(target, in: proxy, over: 0.25)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isFollowing)
            .onChange(of: captions.count) {
                // Cleared, the list starts over at the end.
                if captions.isEmpty { isFollowing = true }
                // Captions fetched ahead arrive below the one being spoken;
                // the list stays on that one rather than running ahead.
                guard isFollowing, target == .end else { return }
                show(.end, in: proxy, over: 0.2)
            }
            .onChange(of: partialText) {
                guard isFollowing, target == .end else { return }
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
            // The sentence the video has moved to, and also the one it is
            // still at when captions fetched ahead land under it: it was
            // the last and followed at the end, which they would take the
            // list along with.
            .onChange(of: Place(playingID: playingID, target: target)) {
                // With nothing playing any more the list stays where it is.
                guard isFollowing, playingID != nil else { return }
                show(target, in: proxy, over: 0.25)
            }
        }
    }

    private func show(_ target: Target, in proxy: ScrollViewProxy, over seconds: Double) {
        withAnimation(.easeOut(duration: seconds)) {
            switch target {
            case .caption(let id): proxy.scrollTo(id, anchor: .center)
            case .end: proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }
}

/// The gap under a row: the playhead splitter while the video is there,
/// else, with the pointer in the gap and a sentence's worth of unheard
/// video in it, a splitter offering to hear it again.
private struct GapBelow: View {
    /// The video's place, when it is in this gap.
    let lull: Lull?
    let fontSize: Double
    let onRehearLull: (() -> Void)?
    /// Hears the gap again; nil when there is nothing in it to hear.
    let onRehear: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        ZStack {
            if let lull {
                PlayheadSplitter(seconds: lull.seconds, fontSize: fontSize, onRehear: onRehearLull)
            } else if isHovered, let onRehear {
                GapSplitter(fontSize: fontSize, onRehear: onRehear)
            }
        }
        // The whole gap, even while nothing is drawn in it: empty, the
        // stack would be a line of no height, and so would the tracker
        // under it, which the pointer could never enter.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if onRehear != nil {
                HoverTracker(isHovered: $isHovered)
            }
        }
    }
}

/// Marks where the video is between two sentences: a line across the list,
/// with the time at its right end, and after it, when the gap can be heard
/// again, the button that does.
struct PlayheadSplitter: View {
    let seconds: Int
    let fontSize: Double
    var onRehear: (() -> Void)? = nil

    static let height: CGFloat = 14
    /// The colour of the video bar's thumb, which is the same place.
    static let color = Color.orange

    var body: some View {
        SplitterLine(
            label: CaptionRow.timestamp(Double(seconds)), color: Self.color, fontSize: fontSize, onRehear: onRehear
        )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Video is here")
            .accessibilityValue(CaptionRow.timestamp(Double(seconds)))
    }
}

/// Offers the gap between two sentences to be heard again: a line across
/// the list with the button at its right end. Shown under the pointer.
struct GapSplitter: View {
    let fontSize: Double
    let onRehear: () -> Void

    static let color = Color.gray

    var body: some View {
        SplitterLine(label: nil, color: Self.color, fontSize: fontSize, onRehear: onRehear)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Nothing captioned here")
    }
}

/// A line across the list with, at its right end, a label and the button
/// that hears the gap again.
struct SplitterLine: View {
    let label: String?
    let color: Color
    let fontSize: Double
    let onRehear: (() -> Void)?

    /// The size of the rows' times, while that fits the gap.
    private var font: Font { .system(size: min(fontSize * 0.55, 12), weight: .semibold) }

    var body: some View {
        HStack(spacing: 8) {
            // Clicks go through the line and the time to the rows; only the
            // button takes them.
            Capsule()
                .fill(color)
                .frame(height: 2)
                .allowsHitTesting(false)
            if let label {
                Text(label)
                    .font(font.monospacedDigit())
                    .foregroundStyle(color)
                    .allowsHitTesting(false)
            }
            if let onRehear {
                Button(action: onRehear) {
                    Image(systemName: Self.symbol)
                        .font(font)
                        .foregroundStyle(color)
                        .frame(width: Self.buttonWidth, height: PlayheadSplitter.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hear this gap again, for a sentence that went uncaptioned")
                .accessibilityLabel("Hear this gap again")
            }
        }
        .frame(height: PlayheadSplitter.height)
    }

    static let symbol = "ear"
    static let buttonWidth: CGFloat = 16
}

/// The captions whose rows are on screen. Only the pill reads it, so a row
/// scrolling in or out redraws the pill and not the list.
@Observable
final class RowsOnScreen {
    var ids: Set<Int> = []
}

/// Takes the list back to what is being said, and to following it. It
/// points the way there while that is out of sight.
private struct ReturnPill: View {
    let captions: [Caption]
    let playingID: Int?
    let onScreen: RowsOnScreen
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(playingID == nil ? "Latest" : "Now playing", systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(white: 0.2)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Return to what is being said, and follow it")
    }

    private var symbol: String {
        let place = Self.place(
            of: playingID.flatMap { id in captions.firstIndex { $0.id == id } } ?? captions.count - 1,
            among: captions.indices.filter { onScreen.ids.contains(captions[$0].id) }
        )
        return switch place {
        case .above: "arrow.up"
        case .below: "arrow.down"
        case .inSight: "scope"
        }
    }

    enum Place {
        case above, below, inSight
    }

    /// Where the row at `index` is from the rows on screen, in list order.
    static func place(of index: Int, among shown: [Int]) -> Place {
        guard let first = shown.first, let last = shown.last else { return .inSight }
        return index < first ? .above : index > last ? .below : .inSight
    }
}

/// Tells when the list is scrolled by hand: by the wheel or the trackpad, or
/// by dragging its scroller. Scrolling done in code is neither. It goes
/// behind the scrolled content, to find the scroll view around it.
struct ScrollWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        WatcherView()
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class WatcherView: NSView {
        var onScroll: () -> Void = {}
        private var monitor: Any?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            monitor = nil
            observer = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window { self.noticed(event, at: event.locationInWindow) }
                return event
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, note.object as? NSScrollView === self.enclosingScrollView else { return }
                self.onScroll()
            }
        }

        /// Tells of a scroll event at `point` of the window when it scrolls
        /// this list up or down. Fingers resting on the trackpad send
        /// events that move nothing, and the glide after a flick only goes
        /// on from a scroll already told of.
        func noticed(_ event: NSEvent, at point: NSPoint) {
            guard let scrollView = enclosingScrollView, event.scrollingDeltaY != 0, event.momentumPhase.isEmpty,
                  scrollView.bounds.contains(scrollView.convert(point, from: nil)), canScroll(scrollView)
            else { return }
            onScroll()
        }

        /// With everything in sight there is nowhere to scroll away to.
        private func canScroll(_ scrollView: NSScrollView) -> Bool {
            (scrollView.documentView?.frame.height ?? 0) > scrollView.contentView.bounds.height + 1
        }
    }
}
