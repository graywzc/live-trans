import AppKit
import SwiftUI

/// The video's audio as a step of the pipeline saw it: a ruler, the audio
/// fetched as a grey band, the stretches of speech the step found (Silero's,
/// FireRedVAD's, or FireRedVAD's and pyannote's averaged, by the picker) as green bars, with what FireRedVAD hears
/// as singing purple and as music alone blue over them, the stretch picked out, and where the video is. Scrolls sideways;
/// pinch, or the slider, to zoom. Click a bar to pick it out, or the gap
/// between two, or drag across the band for any stretch; the stretch can
/// then be heard from the fetched audio, or played in the Chrome video. A
/// click also puts the pointer there (on the ruler, only that), and Space
/// then plays the video from it. The pointer is the one line on the
/// timeline: where it was put, until Space, and then where the video is.
/// Under the band, who speaks when (a colour a speaker, as DiariZen tells
/// the voices apart), and under that the words Whisper alone hears, each
/// where it was said (re-timed by the aligner once all are heard); those
/// outside every stretch of speech are orange, to be checked by ear.
struct StepTimeline: View {
    @Environment(DevPipeline.self) private var dev
    @Environment(Prefetcher.self) private var prefetch
    /// Points per second of the video, kept as its logarithm for the slider.
    @AppStorage("stepTimelineZoom") private var zoom = log(20.0)
    /// How wide the timeline is shown, for fitting the video to it.
    @State private var width: CGFloat = 0
    /// Asks the timeline to bring a moment into view; counted, so asking
    /// for the same moment again does it again.
    @State private var reveal = TimelineCanvas.Reveal(count: 0, seconds: 0)

    /// The closest the zoom comes, in points per second; out, it goes as
    /// far as fitting the whole video, or this, whichever is less.
    static let minimumScale = 4.0
    static let maximumScale = 200.0
    /// Each press of zoom in or out, by this factor.
    static let zoomStep = 2.0

    var body: some View {
        @Bindable var dev = dev
        let scale = exp(zoom)
        let playhead = prefetch.playhead
        let onJob = dev.isOnJob(playhead)
        let total = max(dev.job?.duration ?? playhead?.duration ?? 0, dev.job?.fetched ?? 0, 60)
        let fit = Self.fitScale(width: width, total: total)
        let range = log(min(Self.minimumScale, fit))...log(Self.maximumScale)
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Picker("Step", selection: $dev.step) {
                    ForEach(DevPipeline.Step.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("The step to run; another one runs over the same video, from the audio the host kept")
                Button(action: dev.hearSelection) {
                    Image(systemName: dev.player.isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(dev.selection == nil || dev.job == nil)
                .help(dev.player.isPlaying ? "Stop" : "Hear the stretch from the fetched audio, on what you are listening on")
                Button(action: dev.playSelectionInChrome) {
                    Image(systemName: "play.rectangle")
                }
                .disabled(dev.selection == nil || !onJob)
                .help("Play the stretch in the Chrome video, which pauses at its end")
                Text(Self.summary(selection: dev.selection, speech: dev.speech, job: dev.job, events: dev.events))
                    .foregroundStyle(dev.selection == nil ? Color.gray : Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // Where the pointer is, to the hundredth; it ticks on with
                // the video while the pointer goes with it.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: playhead?.playing != true)) { context in
                    let line = Self.pointer(
                        placed: dev.cursorArmed, cursor: dev.cursor, video: onJob ? prefetch.position : nil,
                        playedFrom: dev.playedFrom, now: context.date
                    )
                    if let at = line.playhead ?? line.cursor {
                        Text("▼ \(Self.readout(at))")
                            .help("Where the pointer is: where you clicked until Space plays from there, then where the video is")
                    }
                }
                .fixedSize()
                PhoneKeepControl(
                    bundle: dev.job?.bundle ?? "none", fetched: dev.job?.bundleFetched ?? 0, duration: dev.job?.duration,
                    canKeep: dev.canKeepForPhone, onKeep: dev.keepForPhone, onForget: dev.forgetPhoneCopy,
                    address: dev.job?.bundleURL, serveError: dev.job?.bundleServeError
                )
                Button(action: dev.forgetCache) {
                    Image(systemName: "trash.slash")
                }
                .help("Have the host forget the videos it fetched and the findings it kept for dev mode")
                Button {
                    let line = Self.pointer(
                        placed: dev.cursorArmed, cursor: dev.cursor, video: onJob ? prefetch.position : nil,
                        playedFrom: dev.playedFrom
                    )
                    if let at = line.playhead ?? line.cursor {
                        reveal = TimelineCanvas.Reveal(count: reveal.count + 1, seconds: at)
                    }
                } label: {
                    Image(systemName: "scope")
                }
                .disabled(dev.cursor == nil && !(onJob && prefetch.position != nil))
                .help("Scroll to the pointer")
                Button { zoom = Self.zoomed(zoom, by: 1 / Self.zoomStep, in: range) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= range.lowerBound + 1e-6)
                .help("Zoom out")
                Button { zoom = Self.zoomed(zoom, by: Self.zoomStep, in: range) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= range.upperBound - 1e-6)
                .help("Zoom in")
                Button { zoom = Self.zoomed(log(fit), by: 1, in: range) } label: {
                    Image(systemName: "arrow.left.and.right.square")
                }
                .help("Fit the whole video")
            }
            .font(.caption.monospacedDigit())
            .buttonStyle(.borderless)
            // Redrawn many times a second while the video plays, so the
            // pointer glides with the video rather than steps.
            let playing = onJob && playhead?.playing == true
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { context in
                let line = Self.pointer(
                    placed: dev.cursorArmed, cursor: dev.cursor, video: onJob ? prefetch.position : nil,
                    playedFrom: dev.playedFrom, now: context.date
                )
                TimelineCanvas(
                    total: total,
                    fetched: dev.job?.fetched ?? 0, analysed: dev.job?.analysed ?? 0, speech: dev.speech, events: dev.events,
                    finder: dev.job?.step.finder ?? dev.step.finder, words: dev.words,
                    wordsAligned: dev.job?.aligned ?? false, speakers: dev.speakers,
                    playhead: line.playhead, selection: dev.selection, cursor: line.cursor, scale: scale,
                    onSelect: { dev.selection = $0 },
                    onPlace: { dev.place(cursor: $0) },
                    onZoom: { zoom = Self.zoomed(zoom, by: $0, in: range) },
                    reveal: reveal
                )
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, new in width = new }
            })
        }
    }

    /// The scale that shows `total` seconds in `width` points.
    static func fitScale(width: CGFloat, total: Double) -> Double {
        guard width > 0, total > 0 else { return minimumScale }
        return Double(width) / total
    }

    /// `zoom`, the logarithm of a scale, times `factor`, kept within `range`.
    static func zoomed(_ zoom: Double, by factor: Double, in range: ClosedRange<Double>) -> Double {
        min(max(zoom + log(factor), range.lowerBound), range.upperBound)
    }

    /// Where the one line on the timeline is, and whether it goes with the
    /// video (`playhead`, drawn moving) or stays where it was put
    /// (`cursor`): put somewhere and not yet played from, it stays; just
    /// played from, it stays there until the video says it has got there,
    /// for up to `seekWait`; else it is where the video is, when the video
    /// is the job's; else where it was last put.
    static func pointer(
        placed: Bool, cursor: Double?, video: Double?,
        playedFrom: (seconds: Double, at: Date)? = nil, now: Date = Date()
    ) -> (playhead: Double?, cursor: Double?) {
        if placed, let cursor { return (nil, cursor) }
        if let playedFrom, now.timeIntervalSince(playedFrom.at) < seekWait,
           video.map({ abs($0 - playedFrom.seconds) > 0.5 }) ?? true {
            return (nil, playedFrom.seconds)
        }
        if let video { return (video, nil) }
        return (nil, cursor)
    }

    /// How long the pointer waits for the video to get where Space sent it.
    static let seekWait: TimeInterval = 2

    /// A moment to the hundredth of a second: "2:37.42", "1:02:37.42".
    static func readout(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        let hours = hundredths / 360_000, minutes = hundredths / 6000 % 60
        let rest = Double(hundredths % 6000) / 100
        return hours > 0
            ? String(format: "%d:%02d:%05.2f", hours, minutes, rest)
            : String(format: "%d:%05.2f", minutes, rest)
    }

    /// What the control row says: of the stretch picked out, else of the
    /// step so far, else how to begin.
    static func summary(
        selection: ClosedRange<Double>?, speech: [ClosedRange<Double>], job: DevPipeline.Job?,
        events: DevPipeline.SoundEvents = DevPipeline.SoundEvents()
    ) -> String {
        guard let job else { return "Press Load under the captions to show the Chrome video's step" }
        guard let selection else {
            let count = speech.count == 1 ? "1 stretch" : "\(speech.count) stretches"
            let state = job.state == "running" && !job.paused ? "so far" : job.state == "done" ? "in all" : job.state
            let key = events.isEmpty ? "" : " · purple: singing, blue: music"
            return "\(count) of speech in \(DevPipeline.clock(job.analysed)) \(state)\(key) · click a bar, or drag across the band"
        }
        let length = String(format: "%.1f s", selection.upperBound - selection.lowerBound)
        var text = "\(DevPipeline.clock(selection.lowerBound))–\(DevPipeline.clock(selection.upperBound)) · \(length)"
        if let stretch = speech.first(where: { $0 == selection }) {
            let pauses = TimelineGeometry.pauses(around: stretch, in: speech)
            let before = pauses.before.map { String(format: "%.2f s", $0) } ?? "none"
            let after = pauses.after.map { String(format: "%.2f s", $0) } ?? "none"
            text += " of speech · pause before \(before), after \(after)"
        } else if speech.contains(where: { min($0.upperBound, selection.upperBound) - max($0.lowerBound, selection.lowerBound) > 1e-6 }) {
            text += " · across speech and pauses"
        } else {
            text += " · no speech"
        }
        for (name, kind) in [("singing", events.singing), ("music", events.music)] {
            let share = TimelineGeometry.share(of: selection, in: kind)
            if share >= 0.05 { text += " · \(Int((share * 100).rounded()))% \(name)" }
        }
        return text
    }
}

/// Where things are on the timeline, in points and seconds.
enum TimelineGeometry {
    /// Tick spacings to choose from, in seconds.
    static let tickSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    static func x(for seconds: Double, scale: Double) -> CGFloat {
        CGFloat(seconds * scale)
    }

    static func seconds(at x: CGFloat, scale: Double) -> Double {
        guard scale > 0 else { return 0 }
        return max(Double(x) / scale, 0)
    }

    /// The seconds between ruler ticks at `scale`: the smallest spacing that
    /// keeps them `apart` points apart.
    static func tickStep(scale: Double, apart: CGFloat = 70) -> Double {
        tickSteps.first { CGFloat($0 * scale) >= apart } ?? tickSteps.last!
    }

    /// Where what is shown starts once the scale goes from `old` to `new`:
    /// the pointer, when it is in view, stays where it is on screen; else
    /// the middle of what is shown stays in the middle. Kept within the
    /// timeline, `width` points wide at the new scale.
    static func zoomedOrigin(
        visible: NSRect, pointer: Double?, from old: Double, to new: Double, width: CGFloat
    ) -> CGFloat {
        var anchor = (seconds: seconds(at: visible.midX, scale: old), offset: visible.width / 2)
        if let pointer {
            let x = self.x(for: pointer, scale: old)
            if x >= visible.minX, x <= visible.maxX { anchor = (pointer, x - visible.minX) }
        }
        let origin = self.x(for: anchor.seconds, scale: new) - anchor.offset
        return min(max(origin, 0), max(width - visible.width, 0))
    }

    /// What a click at `seconds` picks out: the stretch of speech under it,
    /// else the gap it is in, between the stretches either side, or from
    /// the start, or to where the audio ends. Nil past the audio.
    static func pick(at seconds: Double, in speech: [ClosedRange<Double>], fetched: Double) -> ClosedRange<Double>? {
        guard seconds >= 0, seconds <= fetched else { return nil }
        if let stretch = speech.first(where: { $0.contains(seconds) }) { return stretch }
        let from = speech.filter { $0.upperBound <= seconds }.map(\.upperBound).max() ?? 0
        let to = speech.filter { $0.lowerBound >= seconds }.map(\.lowerBound).min() ?? fetched
        return to > from ? from...to : nil
    }

    /// The stretch dragged out from `a` to `b` seconds, kept within the audio.
    static func dragged(from a: Double, to b: Double, fetched: Double) -> ClosedRange<Double>? {
        let low = max(min(a, b), 0), high = min(max(a, b), max(fetched, 0))
        return high > low ? low...high : nil
    }

    /// The pauses either side of `stretch`: to the stretch before it and to
    /// the one after, in seconds, nil where there is none.
    /// What each colour of the band stands for, told when the pointer
    /// rests on it.
    enum Region: Equatable {
        case speech(finder: String)
        case singing
        case music
        case noSpeech
        case notLookedAt
        case notFetched

        var label: String {
            switch self {
            case .speech(let finder): "Speech, as \(finder) found it"
            case .singing: "Singing over the speech, as FireRedVAD's event model hears it"
            case .music: "Music with no voice over the speech, as FireRedVAD's event model hears it"
            case .noSpeech: "No speech found"
            case .notLookedAt: "Fetched, not looked at yet"
            case .notFetched: "Not fetched yet"
            }
        }
    }

    /// The band from 0 to `total`, cut where what it shows changes, each
    /// piece with what it stands for; neighbours alike are one piece.
    static func regions(
        total: Double, fetched: Double, analysed: Double, speech: [ClosedRange<Double>],
        events: DevPipeline.SoundEvents, finder: String
    ) -> [(range: ClosedRange<Double>, region: Region)] {
        let end = max(total, fetched)
        guard end > 0 else { return [] }
        let singing = overlaps(of: events.singing, with: speech), music = overlaps(of: events.music, with: speech)
        var cuts = Set([0, end, min(fetched, end), min(analysed, end)])
        for range in speech + singing + music {
            cuts.insert(min(max(range.lowerBound, 0), end))
            cuts.insert(min(max(range.upperBound, 0), end))
        }
        let points = cuts.sorted()
        var found: [(range: ClosedRange<Double>, region: Region)] = []
        for (from, to) in zip(points, points.dropFirst()) where to > from {
            let middle = (from + to) / 2
            let region: Region
            if singing.contains(where: { $0.contains(middle) }) {
                region = .singing
            } else if music.contains(where: { $0.contains(middle) }) {
                region = .music
            } else if speech.contains(where: { $0.contains(middle) }) {
                region = .speech(finder: finder)
            } else if middle < min(analysed, fetched) {
                region = .noSpeech
            } else if middle < fetched {
                region = .notLookedAt
            } else {
                region = .notFetched
            }
            if let last = found.last, last.region == region, last.range.upperBound == from {
                found[found.count - 1].range = last.range.lowerBound...to
            } else {
                found.append((from...to, region))
            }
        }
        return found
    }

    /// How much of `stretch` the `ranges` cover, from 0 to 1.
    static func share(of stretch: ClosedRange<Double>, in ranges: [ClosedRange<Double>]) -> Double {
        let length = stretch.upperBound - stretch.lowerBound
        guard length > 0 else { return 0 }
        let covered = ranges.reduce(0.0) { $0 + max(min($1.upperBound, stretch.upperBound) - max($1.lowerBound, stretch.lowerBound), 0) }
        return min(covered / length, 1)
    }

    /// Where the `ranges` and the stretches of `speech` overlap.
    static func overlaps(of ranges: [ClosedRange<Double>], with speech: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        ranges.flatMap { range in
            speech.compactMap { stretch -> ClosedRange<Double>? in
                let from = max(range.lowerBound, stretch.lowerBound), to = min(range.upperBound, stretch.upperBound)
                return from < to ? from...to : nil
            }
        }
    }

    static func pauses(around stretch: ClosedRange<Double>, in speech: [ClosedRange<Double>]) -> (before: Double?, after: Double?) {
        let before = speech.filter { $0.upperBound <= stretch.lowerBound + 1e-6 && $0 != stretch }.map(\.upperBound).max()
        let after = speech.filter { $0.lowerBound >= stretch.upperBound - 1e-6 && $0 != stretch }.map(\.lowerBound).min()
        return (before.map { stretch.lowerBound - $0 }, after.map { $0 - stretch.upperBound })
    }

    /// The ruler's label for `seconds`: minutes and seconds, hours when
    /// there are any.
    static func label(_ seconds: Double) -> String {
        CaptionRow.timestamp(seconds)
    }
}

/// The drawn timeline in a sideways scroll view. An AppKit view: it is
/// used while Chrome is the active app, where SwiftUI gestures would spend
/// the press on activating the window.
struct TimelineCanvas: NSViewRepresentable {
    var total: Double
    var fetched: Double
    var analysed: Double
    var speech: [ClosedRange<Double>]
    var events = DevPipeline.SoundEvents()
    /// What found the speech, for the band's labels.
    var finder = "the step"
    /// The words Whisper alone hears, drawn under the band, and whether
    /// their times are the aligner's.
    var words: [HeardWord] = []
    var wordsAligned = false
    /// Who speaks when, drawn between the band and the words.
    var speakers: [SpeakerTurn] = []
    var playhead: Double?
    var selection: ClosedRange<Double>?
    var cursor: Double?
    var scale: Double
    var onSelect: (ClosedRange<Double>?) -> Void
    /// Called with where a click put the pointer.
    var onPlace: (Double) -> Void = { _ in }
    /// Called with the factor pinched by.
    var onZoom: (Double) -> Void
    /// A moment to bring into the middle of what is shown, once per count.
    var reveal = Reveal(count: 0, seconds: 0)

    struct Reveal: Equatable {
        var count: Int
        var seconds: Double
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        let canvas = CanvasView()
        canvas.autoresizingMask = [.height]
        scroll.documentView = canvas
        context.coordinator.scale = scale
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CanvasView else { return }
        let visible = scroll.contentView.bounds
        var redrawAll = canvas.total != total || canvas.fetched != fetched || canvas.analysed != analysed
            || canvas.speech != speech || canvas.events != events || canvas.finder != finder || canvas.words != words
            || canvas.wordsAligned != wordsAligned || canvas.speakers != speakers
            || canvas.selection != selection || canvas.cursor != cursor || canvas.scale != scale
        let wasAt = canvas.playhead
        canvas.total = total
        canvas.fetched = fetched
        canvas.analysed = analysed
        canvas.speech = speech
        canvas.events = events
        canvas.finder = finder
        canvas.words = words
        canvas.wordsAligned = wordsAligned
        canvas.speakers = speakers
        canvas.playhead = playhead
        canvas.selection = selection
        canvas.cursor = cursor
        canvas.scale = scale
        canvas.onSelect = onSelect
        canvas.onPlace = onPlace
        canvas.onZoom = onZoom
        let width = max(TimelineGeometry.x(for: total, scale: scale), scroll.contentSize.width)
        if canvas.frame.width != width || canvas.frame.height != scroll.contentSize.height {
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: scroll.contentSize.height)
            redrawAll = true
        }
        if scale != context.coordinator.scale {
            // Zoomed, the pointer stays where it is on screen, so the
            // moment it marks is not lost.
            let x = TimelineGeometry.zoomedOrigin(
                visible: visible, pointer: playhead ?? cursor, from: context.coordinator.scale, to: scale, width: width
            )
            context.coordinator.scale = scale
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            redrawAll = true
        }
        if redrawAll {
            canvas.needsDisplay = true
            canvas.labelRegions()
        } else if wasAt != playhead {
            // Only the line moved: just its old and new places are drawn
            // again, many times a second.
            canvas.invalidatePlayhead(at: wasAt)
            canvas.invalidatePlayhead(at: playhead)
            // Run off the right of what is shown, the view turns the page.
            if let wasAt, let playhead, visible.contains(NSPoint(x: TimelineGeometry.x(for: wasAt, scale: scale), y: visible.midY)),
               TimelineGeometry.x(for: playhead, scale: scale) >= visible.maxX {
                let x = TimelineGeometry.x(for: playhead, scale: scale) - visible.width / 10
                scroll.contentView.scroll(to: NSPoint(x: min(max(x, 0), max(width - visible.width, 0)), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if reveal.count != context.coordinator.revealed {
            context.coordinator.revealed = reveal.count
            // Once laid out: a view just made is not yet as wide as shown.
            let seconds = reveal.seconds
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, let canvas = scroll.documentView else { return }
                let shown = scroll.contentView.bounds.width
                let x = TimelineGeometry.x(for: seconds, scale: scale) - shown / 2
                scroll.contentView.scroll(to: NSPoint(x: min(max(x, 0), max(canvas.frame.width - shown, 0)), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    final class Coordinator {
        var scale = 0.0
        /// The count of the reveal last done.
        var revealed = 0
    }

    final class CanvasView: NSView, NSViewToolTipOwner {
        static let rulerHeight: CGFloat = 18
        /// A press that moves less than this is a click.
        static let clickSlop: CGFloat = 3

        var total = 60.0
        var fetched = 0.0
        var analysed = 0.0
        var speech: [ClosedRange<Double>] = [] {
            didSet { heard = nil; wordLayout = nil }
        }
        var words: [HeardWord] = [] {
            didSet { if words != oldValue { wordLayout = nil } }
        }
        /// The words as laid out in the lane: each with whether it is
        /// outside the speech, its row of text (none when neither row has
        /// room), and how wide it is drawn; worked out once per change.
        private var wordLayout: [(word: HeardWord, outside: Bool, row: Int?, width: CGFloat)]?
        static let laneHeight: CGFloat = 30
        static let speakerHeight: CGFloat = 12
        var wordsAligned = false
        var speakers: [SpeakerTurn] = []
        /// A colour a speaker, S1 first; past the last, they come round again.
        static let speakerColors: [NSColor] = [
            .systemTeal, .systemPink, .systemYellow, .systemIndigo, .systemMint, .systemBrown, .systemRed, .systemCyan,
        ]

        static func color(of speaker: String) -> NSColor {
            let number = Int(speaker.dropFirst()) ?? 1
            return speakerColors[(max(number, 1) - 1) % speakerColors.count]
        }
        static let wordFont = NSFont.systemFont(ofSize: 10)
        var events = DevPipeline.SoundEvents() {
            didSet { heard = nil }
        }
        /// The parts of the stretches of speech heard as singing and as
        /// music, worked out once for each change of either.
        private var heard: (singing: [ClosedRange<Double>], music: [ClosedRange<Double>])?
        var finder = "the step"
        /// The band's pieces as labelled for the pointer resting on them,
        /// by tool tip tag.
        private(set) var labels: [NSView.ToolTipTag: (rect: NSRect, label: String)] = [:]
        var playhead: Double?
        var selection: ClosedRange<Double>?
        var cursor: Double?
        var scale = 20.0 {
            didSet { if scale != oldValue { wordLayout = nil } }
        }
        var onSelect: (ClosedRange<Double>?) -> Void = { _ in }
        var onPlace: (Double) -> Void = { _ in }
        var onZoom: (Double) -> Void = { _ in }

        /// Where the mouse went down, in the view, and the stretch dragged
        /// out from there so far.
        private var pressed: CGPoint?
        private var dragging: ClosedRange<Double>?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// The band the audio and speech are drawn in, under the ruler.
        var band: NSRect {
            NSRect(
                x: 0, y: Self.rulerHeight + 4, width: bounds.width,
                height: max(bounds.height - Self.rulerHeight - 8 - Self.speakerHeight - Self.laneHeight, 4)
            )
        }

        /// The strip who speaks is drawn in, under the band.
        var speakerLane: NSRect {
            NSRect(x: 0, y: band.maxY + 3, width: bounds.width, height: Self.speakerHeight - 3)
        }

        /// The lane the words are drawn in, under the speakers.
        var lane: NSRect {
            NSRect(x: 0, y: speakerLane.maxY + 3, width: bounds.width, height: Self.laneHeight - 3)
        }

        private func layWords() -> [(word: HeardWord, outside: Bool, row: Int?, width: CGFloat)] {
            if let wordLayout { return wordLayout }
            var rightOf: [CGFloat] = [-.infinity, -.infinity]
            let laid = words.sorted { $0.start < $1.start }.map { word in
                let middle = (word.start + word.end) / 2
                let outside = !speech.contains { $0.contains(middle) }
                let x = TimelineGeometry.x(for: word.start, scale: scale)
                let width = (word.text as NSString).size(withAttributes: [.font: Self.wordFont]).width
                let row = rightOf.firstIndex { $0 + 3 <= x }
                if let row { rightOf[row] = x + width }
                return (word, outside, row, max(width, TimelineGeometry.x(for: word.end, scale: scale) - x))
            }
            wordLayout = laid
            return laid
        }

        /// What a word's label says: the word, when, how sure Whisper is,
        /// and whether the step found speech there.
        static func wordLabel(_ word: HeardWord, outside: Bool, aligned: Bool = false) -> String {
            "「\(word.text)」 \(StepTimeline.readout(word.start))–\(StepTimeline.readout(word.end))"
                + " · Whisper \(String(format: "%.2f", word.probability))"
                + (aligned ? " · times by the aligner" : " · Whisper's times")
                + (outside ? " · outside the speech found" : "")
        }

        /// What a speaker's stretch says when the pointer rests on it.
        static func speakerLabel(_ turn: SpeakerTurn) -> String {
            "Speaker \(turn.speaker) · \(StepTimeline.readout(turn.start))–\(StepTimeline.readout(turn.end))"
                + " · as DiariZen tells the voices apart (S1 speaks most)"
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            // The band grows with the view, and its labels with it.
            if changed { labelRegions() }
        }

        /// Labels each piece of the band with what its colour stands for,
        /// told when the pointer rests on it.
        func labelRegions() {
            removeAllToolTips()
            labels = [:]
            let regions = TimelineGeometry.regions(
                total: total, fetched: fetched, analysed: analysed, speech: speech, events: events, finder: finder
            )
            for (range, region) in regions {
                let area = rect(range, in: band)
                guard area.width > 0, area.height > 0 else { continue }
                labels[addToolTip(area, owner: self, userData: nil)] = (area, region.label)
            }
            for (word, outside, _, width) in layWords() {
                let area = NSRect(x: TimelineGeometry.x(for: word.start, scale: scale), y: lane.minY, width: max(width, 2), height: lane.height)
                labels[addToolTip(area, owner: self, userData: nil)] = (area, Self.wordLabel(word, outside: outside, aligned: wordsAligned))
            }
            for turn in speakers {
                let area = rect(turn.range, in: speakerLane)
                guard area.width > 0 else { continue }
                labels[addToolTip(area, owner: self, userData: nil)] = (area, Self.speakerLabel(turn))
            }
        }

        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
            labels[tag]?.label ?? ""
        }

        /// What the band says at `point`, in the view, when the pointer
        /// rests there.
        func label(at point: NSPoint) -> String? {
            labels.values.first { $0.rect.contains(point) }?.label
        }

        /// Marks the strip the playhead's line takes at `seconds` for drawing.
        func invalidatePlayhead(at seconds: Double?) {
            guard let seconds else { return }
            let x = TimelineGeometry.x(for: seconds, scale: scale)
            setNeedsDisplay(NSRect(x: x - 5, y: 0, width: 10, height: bounds.height))
        }

        private func rect(_ range: ClosedRange<Double>, in area: NSRect) -> NSRect {
            let from = TimelineGeometry.x(for: range.lowerBound, scale: scale)
            let to = TimelineGeometry.x(for: range.upperBound, scale: scale)
            return NSRect(x: from, y: area.minY, width: max(to - from, 1), height: area.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            let band = band
            let shown = TimelineGeometry.seconds(at: dirtyRect.minX, scale: scale)...TimelineGeometry.seconds(at: dirtyRect.maxX, scale: scale)
            NSColor.white.withAlphaComponent(0.08).setFill()
            rect(0...total, in: band).intersection(dirtyRect).fill()
            if fetched > 0 {
                NSColor.white.withAlphaComponent(0.12).setFill()
                rect(0...fetched, in: band).intersection(dirtyRect).fill()
            }
            if analysed > 0 {
                NSColor.white.withAlphaComponent(0.1).setFill()
                rect(0...analysed, in: band).intersection(dirtyRect).fill()
            }
            NSColor.systemGreen.withAlphaComponent(0.75).setFill()
            for stretch in speech where stretch.overlaps(shown) {
                rect(stretch, in: band.insetBy(dx: 0, dy: 2)).fill()
            }
            if !events.isEmpty {
                let heard = heard ?? (
                    TimelineGeometry.overlaps(of: events.singing, with: speech),
                    TimelineGeometry.overlaps(of: events.music, with: speech)
                )
                self.heard = heard
                for (color, parts) in [(NSColor.systemPurple, heard.singing), (NSColor.systemBlue, heard.music)] {
                    color.withAlphaComponent(0.9).setFill()
                    for part in parts where part.overlaps(shown) {
                        rect(part, in: band.insetBy(dx: 0, dy: 2)).fill()
                    }
                }
            }
            if let picked = dragging ?? selection {
                let area = rect(picked, in: band)
                NSColor.systemOrange.withAlphaComponent(0.3).setFill()
                area.fill()
                NSColor.systemOrange.setStroke()
                let path = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
            drawSpeakers(in: dirtyRect)
            drawWords(in: dirtyRect)
            drawRuler(in: dirtyRect)
            // The pointer, put there or going with the video: one look.
            if let at = playhead ?? cursor {
                let x = TimelineGeometry.x(for: at, scale: scale)
                NSColor.white.setFill()
                // Put somewhere, on whole pixels, so the line is sharp rather
                // than two grey halves; going with the video, where it is,
                // so it glides rather than steps.
                let pixels = window?.backingScaleFactor ?? 2
                let left = playhead == nil ? ((x - 1) * pixels).rounded() / pixels : x - 1
                NSRect(x: left, y: 0, width: 2, height: bounds.height).intersection(dirtyRect).fill()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: x - 4, y: 0))
                mark.line(to: NSPoint(x: x + 4, y: 0))
                mark.line(to: NSPoint(x: x, y: 6))
                mark.close()
                mark.fill()
            }
        }

        private func drawSpeakers(in dirtyRect: NSRect) {
            let lane = speakerLane
            guard !speakers.isEmpty, lane.intersects(dirtyRect) else { return }
            for turn in speakers {
                let area = rect(turn.range, in: lane)
                guard area.intersects(dirtyRect) else { continue }
                Self.color(of: turn.speaker).withAlphaComponent(0.9).setFill()
                area.fill()
            }
        }

        private func drawWords(in dirtyRect: NSRect) {
            let lane = lane
            guard !words.isEmpty, lane.intersects(dirtyRect) else { return }
            for (word, outside, row, width) in layWords() {
                let x = TimelineGeometry.x(for: word.start, scale: scale)
                guard x <= dirtyRect.maxX, x + width >= dirtyRect.minX else { continue }
                let color = outside ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.8)
                color.setFill()
                rect(word.range, in: NSRect(x: 0, y: lane.minY, width: 0, height: 2)).fill()
                if let row {
                    (word.text as NSString).draw(
                        at: NSPoint(x: x, y: lane.minY + 3 + CGFloat(row) * 12),
                        withAttributes: [.font: Self.wordFont, .foregroundColor: color]
                    )
                }
            }
        }

        private func drawRuler(in dirtyRect: NSRect) {
            let step = TimelineGeometry.tickStep(scale: scale)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray]
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).intersection(dirtyRect).fill()
            let first = (TimelineGeometry.seconds(at: dirtyRect.minX, scale: scale) / step).rounded(.down) * step
            var at = max(first - step, 0)
            while at <= total + step {
                let x = TimelineGeometry.x(for: at, scale: scale)
                if x > dirtyRect.maxX + 80 { break }
                NSRect(x: x, y: Self.rulerHeight - 5, width: 1, height: 4).fill()
                if x >= dirtyRect.minX - 80 {
                    TimelineGeometry.label(at).draw(at: NSPoint(x: x + 2, y: 1), withAttributes: attributes)
                }
                at += step
            }
        }

        override func mouseDown(with event: NSEvent) {
            pressed = convert(event.locationInWindow, from: nil)
            dragging = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed else { return }
            let x = convert(event.locationInWindow, from: nil).x
            guard abs(x - pressed.x) >= Self.clickSlop || dragging != nil else { return }
            dragging = TimelineGeometry.dragged(
                from: TimelineGeometry.seconds(at: pressed.x, scale: scale),
                to: TimelineGeometry.seconds(at: x, scale: scale), fetched: fetched
            )
            autoscroll(with: event)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            guard let pressed else { return }
            let x = convert(event.locationInWindow, from: nil).x
            self.pressed = nil
            if abs(x - pressed.x) < Self.clickSlop && dragging == nil {
                // A click: the pointer goes there; in the band, the stretch
                // under it is picked out too.
                let seconds = TimelineGeometry.seconds(at: x, scale: scale)
                onPlace(min(seconds, max(total, 0)))
                if pressed.y >= Self.rulerHeight {
                    onSelect(TimelineGeometry.pick(at: seconds, in: speech, fetched: fetched))
                }
            } else {
                onSelect(dragging)
            }
            dragging = nil
            needsDisplay = true
        }

        override func magnify(with event: NSEvent) {
            onZoom(1 + event.magnification)
        }
    }
}

/// The divider between the timeline and the log; drag it to give either
/// more room. Tells how far it was dragged, downwards positive.
struct RowSplitHandle: NSViewRepresentable {
    static let height: CGFloat = 7

    let onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HandleView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: Self.height)
    }

    final class HandleView: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }
        private var lastY: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            lastY = event.locationInWindow.y
        }

        override func mouseDragged(with event: NSEvent) {
            // Window coordinates go up; a drag down is a smaller y.
            let y = event.locationInWindow.y
            onDrag(lastY - y)
            lastY = y
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }
    }
}
