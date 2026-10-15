import AppKit
import SwiftUI

/// The video's audio as a step of the pipeline saw it: a ruler, the audio
/// fetched as a grey band, the stretches of speech the step found (Silero's
/// or FireRedVAD's, by the picker) as green bars, the stretch picked out, and where the video is. Scrolls sideways;
/// pinch, or the slider, to zoom. Click a bar to pick it out, or the gap
/// between two, or drag across the band for any stretch; the stretch can
/// then be heard from the fetched audio, or played in the Chrome video. A
/// click also puts the pointer there (on the ruler, only that), and Space
/// then plays the video from it.
struct StepTimeline: View {
    @Environment(DevPipeline.self) private var dev
    @Environment(Prefetcher.self) private var prefetch
    /// Points per second of the video, kept as its logarithm for the slider.
    @AppStorage("stepTimelineZoom") private var zoom = log(20.0)

    static let minimumScale = 4.0
    static let maximumScale = 200.0

    var body: some View {
        @Bindable var dev = dev
        let scale = exp(zoom)
        let playhead = prefetch.playhead
        let onJob = dev.isOnJob(playhead)
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
                Text(Self.summary(selection: dev.selection, speech: dev.speech, job: dev.job))
                    .foregroundStyle(dev.selection == nil ? Color.gray : Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // Where the pointer and the video are, to the hundredth;
                // the video's ticks on while it plays.
                if let cursor = dev.cursor {
                    Text("▼ \(Self.readout(cursor))")
                        .help("Where the pointer is")
                }
                if onJob {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: playhead?.playing != true)) { _ in
                        if let position = prefetch.position {
                            HStack(spacing: 3) {
                                Text("●").foregroundStyle(Color.orange)
                                Text(Self.readout(position))
                            }
                            .help("Where the video is")
                        }
                    }
                    .fixedSize()
                }
                Button(action: dev.forgetCache) {
                    Image(systemName: "trash.slash")
                }
                .help("Have the host forget the videos it fetched and the findings it kept for dev mode")
                Slider(value: $zoom, in: log(Self.minimumScale)...log(Self.maximumScale))
                    .frame(width: 72)
                    .help("Zoom")
            }
            .font(.caption.monospacedDigit())
            .buttonStyle(.borderless)
            // Redrawn many times a second while the video plays, so the
            // orange line moves rather than steps.
            let playing = onJob && playhead?.playing == true
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { _ in
                TimelineCanvas(
                    total: max(dev.job?.duration ?? playhead?.duration ?? 0, dev.job?.fetched ?? 0, 60),
                    fetched: dev.job?.fetched ?? 0, analysed: dev.job?.analysed ?? 0, speech: dev.speech,
                    playhead: onJob ? prefetch.position : nil, selection: dev.selection, cursor: dev.cursor, scale: scale,
                    onSelect: { dev.selection = $0 },
                    onPlace: { dev.place(cursor: $0) },
                    onZoom: { zoom = min(max(zoom + log($0), log(Self.minimumScale)), log(Self.maximumScale)) }
                )
            }
        }
    }

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
    static func summary(selection: ClosedRange<Double>?, speech: [ClosedRange<Double>], job: DevPipeline.Job?) -> String {
        guard let job else { return "Press Run step under the captions to fetch the Chrome video" }
        guard let selection else {
            let count = speech.count == 1 ? "1 stretch" : "\(speech.count) stretches"
            let state = job.state == "running" && !job.paused ? "so far" : job.state == "done" ? "in all" : job.state
            return "\(count) of speech in \(DevPipeline.clock(job.analysed)) \(state) · click a bar, or drag across the band"
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
    var playhead: Double?
    var selection: ClosedRange<Double>?
    var cursor: Double?
    var scale: Double
    var onSelect: (ClosedRange<Double>?) -> Void
    /// Called with where a click put the pointer.
    var onPlace: (Double) -> Void = { _ in }
    /// Called with the factor pinched by.
    var onZoom: (Double) -> Void

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
        // Zoomed, the middle of what is shown stays in the middle.
        let visible = scroll.contentView.bounds
        let middle = TimelineGeometry.seconds(at: visible.midX, scale: context.coordinator.scale)
        var redrawAll = canvas.total != total || canvas.fetched != fetched || canvas.analysed != analysed
            || canvas.speech != speech || canvas.selection != selection || canvas.cursor != cursor || canvas.scale != scale
        let wasAt = canvas.playhead
        canvas.total = total
        canvas.fetched = fetched
        canvas.analysed = analysed
        canvas.speech = speech
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
            context.coordinator.scale = scale
            let x = TimelineGeometry.x(for: middle, scale: scale) - visible.width / 2
            scroll.contentView.scroll(to: NSPoint(x: min(max(x, 0), max(width - visible.width, 0)), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            redrawAll = true
        }
        if redrawAll {
            canvas.needsDisplay = true
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
    }

    final class Coordinator {
        var scale = 0.0
    }

    final class CanvasView: NSView {
        static let rulerHeight: CGFloat = 18
        /// A press that moves less than this is a click.
        static let clickSlop: CGFloat = 3

        var total = 60.0
        var fetched = 0.0
        var analysed = 0.0
        var speech: [ClosedRange<Double>] = []
        var playhead: Double?
        var selection: ClosedRange<Double>?
        var cursor: Double?
        var scale = 20.0
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
            NSRect(x: 0, y: Self.rulerHeight + 4, width: bounds.width, height: max(bounds.height - Self.rulerHeight - 8, 4))
        }

        /// Marks the strip the playhead's line takes at `seconds` for drawing.
        func invalidatePlayhead(at seconds: Double?) {
            guard let seconds else { return }
            let x = TimelineGeometry.x(for: seconds, scale: scale)
            setNeedsDisplay(NSRect(x: x - 2, y: 0, width: 4, height: bounds.height))
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
            if let picked = dragging ?? selection {
                let area = rect(picked, in: band)
                NSColor.systemOrange.withAlphaComponent(0.3).setFill()
                area.fill()
                NSColor.systemOrange.setStroke()
                let path = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            }
            drawRuler(in: dirtyRect)
            if let cursor {
                let x = TimelineGeometry.x(for: cursor, scale: scale)
                NSColor.white.setFill()
                NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).intersection(dirtyRect).fill()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: x - 4, y: 0))
                mark.line(to: NSPoint(x: x + 4, y: 0))
                mark.line(to: NSPoint(x: x, y: 6))
                mark.close()
                mark.fill()
            }
            if let playhead {
                let x = TimelineGeometry.x(for: playhead, scale: scale)
                NSColor.systemOrange.setFill()
                NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).intersection(dirtyRect).fill()
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
