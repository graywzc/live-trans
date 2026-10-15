import SwiftUI
import XCTest
@testable import LiveTrans

/// The dev mode's timeline: where things are on it, and what a click or a
/// drag on it in a real window picks out.
@MainActor
final class StepTimelineTests: XCTestCase {
    private var window: NSWindow!
    private var picked: [ClosedRange<Double>?] = []
    private var placed: [Double] = []

    private static let size = CGSize(width: 480, height: 120)
    private static let speech: [ClosedRange<Double>] = [1.0...3.0, 4.0...5.5, 8.0...8.4]

    override func setUp() async throws {
        picked = []
        placed = []
        window = TestScreen.window(size: Self.size)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    // MARK: Geometry

    func testPointsAndSecondsAreEachOthersInverse() {
        XCTAssertEqual(TimelineGeometry.x(for: 12.5, scale: 20), 250)
        XCTAssertEqual(TimelineGeometry.seconds(at: 250, scale: 20), 12.5)
        XCTAssertEqual(TimelineGeometry.seconds(at: -10, scale: 20), 0, "nothing before the start")
    }

    func testTicksKeepTheirDistanceAsTheScaleChanges() {
        XCTAssertEqual(TimelineGeometry.tickStep(scale: 100), 1)
        XCTAssertEqual(TimelineGeometry.tickStep(scale: 20), 5)
        XCTAssertEqual(TimelineGeometry.tickStep(scale: 4), 30)
        XCTAssertEqual(TimelineGeometry.tickStep(scale: 0.01), 3600, "never closer than the widest step")
    }

    func testAClickPicksTheStretchUnderItOrTheGapItIsIn() {
        XCTAssertEqual(TimelineGeometry.pick(at: 2.0, in: Self.speech, fetched: 10), 1.0...3.0)
        XCTAssertEqual(TimelineGeometry.pick(at: 3.5, in: Self.speech, fetched: 10), 3.0...4.0, "the pause between two")
        XCTAssertEqual(TimelineGeometry.pick(at: 0.5, in: Self.speech, fetched: 10), 0.0...1.0, "from the start")
        XCTAssertEqual(TimelineGeometry.pick(at: 9.0, in: Self.speech, fetched: 10), 8.4...10.0, "to where the audio ends")
        XCTAssertNil(TimelineGeometry.pick(at: 11.0, in: Self.speech, fetched: 10), "nothing past the audio")
        XCTAssertNil(TimelineGeometry.pick(at: 2.0, in: [], fetched: 0), "nothing before any audio")
    }

    func testADragIsKeptWithinTheAudio() {
        XCTAssertEqual(TimelineGeometry.dragged(from: 6, to: 2, fetched: 10), 2...6, "either way round")
        XCTAssertEqual(TimelineGeometry.dragged(from: -2, to: 12, fetched: 10), 0...10)
        XCTAssertNil(TimelineGeometry.dragged(from: 12, to: 14, fetched: 10))
    }

    func testThePausesEitherSideOfAStretch() {
        let middle = TimelineGeometry.pauses(around: 4.0...5.5, in: Self.speech)
        XCTAssertEqual(middle.before, 1.0)
        XCTAssertEqual(middle.after, 2.5)
        let first = TimelineGeometry.pauses(around: 1.0...3.0, in: Self.speech)
        XCTAssertNil(first.before)
        XCTAssertEqual(first.after, 1.0)
        let last = TimelineGeometry.pauses(around: 8.0...8.4, in: Self.speech)
        XCTAssertEqual(last.before, 2.5)
        XCTAssertNil(last.after)
    }

    func testWhatTheControlRowSays() {
        XCTAssertEqual(
            StepTimeline.summary(selection: nil, speech: [], job: nil),
            "Press Run step under the captions to fetch the Chrome video"
        )
        var job = DevPipeline.Job(id: "a", tabID: 1, page: "https://example.com/v", step: .speech, duration: 600)
        job.fetched = 130
        job.analysed = 125
        XCTAssertEqual(
            StepTimeline.summary(selection: nil, speech: Self.speech, job: job),
            "3 stretches of speech in 2:05.0 so far · click a bar, or drag across the band"
        )
        XCTAssertEqual(
            StepTimeline.summary(selection: 4.0...5.5, speech: Self.speech, job: job),
            "0:04.0–0:05.5 · 1.5 s of speech · pause before 1.00 s, after 2.50 s"
        )
        XCTAssertEqual(
            StepTimeline.summary(selection: 3.0...4.0, speech: Self.speech, job: job),
            "0:03.0–0:04.0 · 1.0 s · no speech"
        )
        XCTAssertEqual(
            StepTimeline.summary(selection: 2.0...6.0, speech: Self.speech, job: job),
            "0:02.0–0:06.0 · 4.0 s · across speech and pauses"
        )
        job.state = "done"
        XCTAssertTrue(StepTimeline.summary(selection: nil, speech: Self.speech, job: job).contains("in all"))
    }

    func testTheReadoutsGoToTheHundredth() {
        XCTAssertEqual(StepTimeline.readout(157.424), "2:37.42")
        XCTAssertEqual(StepTimeline.readout(4.006), "0:04.01")
        XCTAssertEqual(StepTimeline.readout(59.999), "1:00.00")
        XCTAssertEqual(StepTimeline.readout(3757.4), "1:02:37.40")
        XCTAssertEqual(StepTimeline.readout(-1), "0:00.00")
    }

    func testTheHostStatusTellsOfTheStep() {
        var job = DevPipeline.Job(id: "abcdef", tabID: 1, page: "p", step: .speech, duration: 1440)
        job.fetched = 412
        job.analysed = 380
        XCTAssertEqual(
            ActivityView.hostStatus(.listening("GPU · large-v3"), job: nil, step: job),
            "GPU · large-v3\nStep 1 · Speech (Silero) running · fetched to 6:52 · looked to 6:20 of 24:00"
        )
    }

    // MARK: In a window

    /// The canvas fills the window at 20 points per second, so a second
    /// is 20 points from the left edge.
    private func show(scale: Double = 20, selection: ClosedRange<Double>? = nil) {
        let canvas = TimelineCanvas(
            total: 20, fetched: 10, analysed: 10, speech: Self.speech, playhead: 2.5, selection: selection,
            scale: scale, onSelect: { [unowned self] in picked.append($0) },
            onPlace: { [unowned self] in placed.append($0) }, onZoom: { _ in }
        )
        window.contentView = NSHostingView(
            rootView: canvas.frame(width: Self.size.width, height: Self.size.height).background(Color.black)
        )
        window.makeKeyAndOrderFront(nil)
        pump()
    }

    private var bandY: CGFloat { TimelineCanvas.CanvasView.rulerHeight + 40 }

    func testClickingABarPicksItOut() {
        show()
        drag(from: CGPoint(x: 40, y: bandY), to: CGPoint(x: 41, y: bandY))
        XCTAssertEqual(picked, [1.0...3.0])
        show(selection: 1.0...3.0)
        snapshot("step-timeline-picked")
        XCTAssertTrue(isLit(CGRect(x: 20, y: bandY - 5, width: 40, height: 10), hue: .orange), "the bar is marked orange")
        XCTAssertTrue(isLit(CGRect(x: 80, y: bandY - 5, width: 30, height: 10), hue: .green), "the next is still green")
    }

    func testClickingAGapPicksThePause() {
        show()
        drag(from: CGPoint(x: 70, y: bandY), to: CGPoint(x: 70, y: bandY))
        XCTAssertEqual(picked, [3.0...4.0])
    }

    func testAClickPutsThePointerThereAndOnTheRulerOnlyThat() {
        show()
        drag(from: CGPoint(x: 70, y: bandY), to: CGPoint(x: 70, y: bandY))
        XCTAssertEqual(placed, [3.5])
        XCTAssertEqual(picked.count, 1)
        drag(from: CGPoint(x: 100, y: 8), to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(placed, [3.5, 5.0])
        XCTAssertEqual(picked.count, 1, "a click on the ruler picks nothing out")
        drag(from: CGPoint(x: 40, y: bandY), to: CGPoint(x: 120, y: bandY))
        XCTAssertEqual(placed, [3.5, 5.0], "a drag does not move the pointer")
    }

    func testTheStepsAreTheHostsAndTheChoiceIsKept() {
        // The names the host's DEV_STEPS knows them by.
        XCTAssertEqual(DevPipeline.Step.allCases.map(\.rawValue), ["speech", "speech-firered"])
        let kept = UserDefaults.standard.string(forKey: AppSettings.pipelineStep)
        defer { UserDefaults.standard.set(kept, forKey: AppSettings.pipelineStep) }
        let dev = DevPipeline(engine: CaptionEngine(), video: ChromeVideo())
        dev.step = .speechFireRed
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.pipelineStep), "speech-firered")
        XCTAssertEqual(DevPipeline(engine: CaptionEngine(), video: ChromeVideo()).step, .speechFireRed)
        dev.step = .speech
        XCTAssertEqual(DevPipeline(engine: CaptionEngine(), video: ChromeVideo()).step, .speech)
    }

    func testSpacePlaysFromThePointerOnceItHasBeenPut() {
        let dev = DevPipeline(engine: CaptionEngine(), video: ChromeVideo())
        XCTAssertFalse(dev.playFromCursor(), "nothing to play from")
        var job = DevPipeline.Job(id: "a", tabID: 1, page: "https://example.com/v", step: .speech, duration: 60)
        job.fetched = 30
        dev.show(job: job, speech: Self.speech)
        dev.place(cursor: 3.5)
        XCTAssertEqual(dev.cursor, 3.5)
        XCTAssertTrue(dev.playFromCursor(), "the first Space after a click plays from there")
        XCTAssertFalse(dev.playFromCursor(), "the next is Space as usual")
        dev.place(cursor: 7)
        XCTAssertTrue(dev.playFromCursor())
    }

    func testDraggingAcrossTheBandPicksTheStretchDraggedOut() {
        show()
        drag(from: CGPoint(x: 40, y: bandY), to: CGPoint(x: 120, y: bandY))
        XCTAssertEqual(picked.count, 1)
        let range = picked.first ?? nil
        XCTAssertEqual(range?.lowerBound ?? -1, 2.0, accuracy: 0.1)
        XCTAssertEqual(range?.upperBound ?? -1, 6.0, accuracy: 0.1)
    }

    func testClickingPastTheAudioPicksNothing() {
        show()
        drag(from: CGPoint(x: 300, y: bandY), to: CGPoint(x: 300, y: bandY))
        XCTAssertEqual(picked, [nil])
    }

    func testThePlayheadIsDrawnWhereTheVideoIs() {
        show()
        XCTAssertTrue(isLit(CGRect(x: 48, y: 4, width: 4, height: 10), hue: .orange), "a line at 2.5 s, over the ruler too")
        XCTAssertFalse(isLit(CGRect(x: 60, y: 4, width: 4, height: 8), hue: .orange))
    }

    private enum Hue {
        case orange
        case green
    }

    /// Whether anything of `hue` is drawn in `rect`, from the window's top left.
    private func isLit(_ rect: CGRect, hue: Hue) -> Bool {
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) else { continue }
                switch hue {
                case .orange where color.redComponent > 0.5 && color.redComponent > color.greenComponent * 1.3 && color.blueComponent < 0.4:
                    return true
                case .green where color.greenComponent > 0.4 && color.greenComponent > color.redComponent * 1.5:
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        NSApp.postEvent(event(.leftMouseDown, at: start), atStart: false)
        if start != end {
            NSApp.postEvent(event(.leftMouseDragged, at: end), atStart: false)
        }
        NSApp.postEvent(event(.leftMouseUp, at: end), atStart: false)
        pump()
    }

    private func pump() {
        while let event = NSApp.nextEvent(
            matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
    }

    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
