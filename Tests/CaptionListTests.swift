import SwiftUI
import XCTest
@testable import LiveTrans

/// The caption list keeping to what is being said: the end for live
/// captions, the sentence the video is at among ones fetched ahead, and
/// nowhere at all once it has been scrolled by hand, until the pill is
/// pressed.
@MainActor
final class CaptionListTests: XCTestCase {
    @Observable
    final class Model {
        var captions: [Caption] = []
        var partial = ""
        var playingID: Int?
        var lull: Lull?
        /// The captions with a gap under them that can be heard again.
        var rehearable: Set<Int> = []
        var reheard: [Int] = []
        var canRehearLull = false
        var lullReheard = 0
    }

    struct Host: View {
        let model: Model

        var body: some View {
            CaptionList(
                captions: model.captions, partialText: model.partial, fontSize: 16, playingID: model.playingID,
                lull: model.lull, lullRehearing: model.canRehearLull ? { model.lullReheard += 1 } : nil,
                gapRehearing: { caption in
                    model.rehearable.contains(caption.id) ? { model.reheard.append(caption.id) } : nil
                }
            ) { caption in
                Text(caption.japanese)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
                    .background(caption.id == model.playingID ? Color.green.opacity(0.3) : .clear)
            }
            .frame(width: 400, height: 300)
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }

    private let model = Model()
    private var window: NSWindow!

    override func setUp() async throws {
        window = TestScreen.window(width: 400, height: 300)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFrontRegardless()
        pump()
    }

    override func tearDown() async throws {
        window.close()
    }

    func testLiveCaptionsAreFollowedAtTheEnd() throws {
        add(30)
        add(5)
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
        model.partial = "聞こえてくる途中の"
        settle()
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
        XCTAssertFalse(try pillShows())
        snapshot("list-live")
    }

    func testCaptionsFetchedAheadLeaveTheListOnTheSentenceBeingPlayed() throws {
        add(40)
        model.playingID = 10
        settle()
        let playing = try offset()
        XCTAssertLessThan(playing, try end() - 300, "the list should have left the end for the sentence")
        snapshot("list-playing")

        // More of the video is captioned, through a pause in the talk and
        // with a word of the live preview slipping in.
        add(10)
        model.partial = "えっと"
        settle()
        model.partial = ""
        add(10)
        // Within a third of a row: a lazy stack shifts a little as it
        // measures what it was only estimating, by an amount that differs
        // between machines (2 points on one, 7 on another), where the jump
        // guarded against is a screenful.
        XCTAssertEqual(try offset(), playing, accuracy: 20)

        model.playingID = 11
        settle()
        XCTAssertEqual(try offset(), playing + 58, accuracy: 20)
        XCTAssertFalse(try pillShows())
    }

    func testScrolledByHandItStaysUntilThePillIsPressed() throws {
        add(40)
        model.playingID = 10
        settle()
        let playing = try offset()
        XCTAssertFalse(try pillShows())

        try scroll(by: -400)
        let away = try offset()
        XCTAssertGreaterThan(away, playing + 300)
        snapshot("list-scrolled-away")
        XCTAssertTrue(try pillShows(), "no pill after scrolling away")

        model.playingID = 11
        add(10)
        XCTAssertEqual(try offset(), away, accuracy: 20)

        clickPill()
        XCTAssertEqual(try offset(), playing + 58, accuracy: 20)
        XCTAssertFalse(try pillShows())
        snapshot("list-returned")
        model.playingID = 12
        settle()
        XCTAssertEqual(try offset(), playing + 116, accuracy: 20)
    }

    func testThePillTakesLiveCaptionsBackToTheEnd() throws {
        add(40)
        try scroll(by: 600)
        let away = try offset()
        XCTAssertLessThan(away, try end() - 300)
        add(5)
        XCTAssertEqual(try offset(), away, accuracy: 20)
        snapshot("list-live-scrolled-away")

        XCTAssertTrue(try pillShows(), "no pill after scrolling away")
        clickPill()
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
        add(5)
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
    }

    func testBetweenSentencesASplitterMarksWhereTheVideoIs() throws {
        // Five rows 40 high and 18 apart, all in sight at the foot of the
        // list: the gap under the third is centred 174 down.
        add(5)
        let gap = CGPoint(x: 150, y: 174)
        let height = try XCTUnwrap(scrollView().documentView).frame.height
        XCTAssertFalse(try isOrange(at: gap))

        model.lull = Lull(captionID: 2, isAfter: true, seconds: 754)
        settle()
        XCTAssertTrue(try isOrange(at: gap), "no splitter after the sentence just played")
        XCTAssertFalse(try isOrange(at: CGPoint(x: gap.x, y: gap.y - 58)))
        XCTAssertFalse(try isOrange(at: CGPoint(x: gap.x, y: gap.y + 58)))
        // It takes no room of its own, so the list does not shift under it.
        XCTAssertEqual(try XCTUnwrap(scrollView().documentView).frame.height, height)
        snapshot("list-lull")

        model.lull = Lull(captionID: 3, isAfter: true, seconds: 761)
        settle()
        XCTAssertFalse(try isOrange(at: gap))
        XCTAssertTrue(try isOrange(at: CGPoint(x: gap.x, y: gap.y + 58)))

        model.lull = nil
        settle()
        XCTAssertFalse(try isOrange(at: CGPoint(x: gap.x, y: gap.y + 58)))
    }

    func testBeforeTheFirstSentenceTheSplitterIsAboveIt() throws {
        add(3)
        model.lull = Lull(captionID: 0, isAfter: false, seconds: 5)
        settle()
        snapshot("list-lull-before")
        // Three rows at the foot of the list, and the splitter over them.
        let firstRow: CGFloat = 300 - 1 - 18 - 3 * 40 - 2 * 18
        let splitter = CGPoint(x: 150, y: firstRow - 18 - PlayheadSplitter.height / 2)
        XCTAssertTrue(try isOrange(at: splitter))
    }

    func testUnderThePointerAGapOffersToBeHeardAgain() throws {
        // Five rows 40 high and 18 apart, all in sight at the foot of the
        // list: the gap under the third is centred 174 down.
        add(5)
        model.rehearable = [2]
        settle()
        let gap = CGPoint(x: 150, y: 174)
        XCTAssertFalse(try isGrey(at: gap))
        // Only a gap with something to hear tracks the pointer.
        let trackers = try gapTrackers()
        XCTAssertEqual(trackers.count, 1)
        let tracker = trackers[0]
        let frame = tracker.convert(tracker.bounds, to: nil)
        XCTAssertEqual(300 - frame.midY, gap.y, accuracy: 1, "the tracker should be in the gap under the third row")
        // The whole gap, with nothing drawn in it yet: a tracker of no
        // height is one the pointer never enters.
        XCTAssertEqual(frame.height, 18, accuracy: 1)
        XCTAssertGreaterThan(frame.width, 300)

        tracker.mouseEntered(with: event(.mouseMoved, at: gap))
        pump()
        XCTAssertTrue(try isGrey(at: gap), "no splitter under the pointer")
        snapshot("list-gap-hovered")
        // The button sits at the right end of the line.
        let button = CGPoint(x: frame.maxX - SplitterLine.buttonWidth / 2, y: gap.y)
        click(button)
        XCTAssertEqual(model.reheard, [2])

        tracker.mouseExited(with: event(.mouseMoved, at: gap))
        pump()
        XCTAssertFalse(try isGrey(at: gap))
        click(button)
        XCTAssertEqual(model.reheard, [2], "hidden, the button must not take clicks")
    }

    func testTheSplitterHasTheButtonWhereTheVideoIsInAGap() throws {
        add(5)
        model.rehearable = [2]
        model.canRehearLull = true
        model.lull = Lull(captionID: 2, isAfter: true, seconds: 754)
        settle()
        let gap = CGPoint(x: 150, y: 174)
        XCTAssertTrue(try isOrange(at: gap))
        snapshot("list-lull-rehear")
        let tracker = try XCTUnwrap(gapTrackers().first)
        let frame = tracker.convert(tracker.bounds, to: nil)
        tracker.mouseEntered(with: event(.mouseMoved, at: gap))
        pump()
        // Under the pointer it is still the video's splitter, and its
        // button hears the gap the video is in.
        XCTAssertTrue(try isOrange(at: gap))
        click(CGPoint(x: frame.maxX - SplitterLine.buttonWidth / 2, y: gap.y))
        XCTAssertEqual(model.lullReheard, 1)
        XCTAssertEqual(model.reheard, [])
    }

    func testRestingOnTheTrackpadIsNotScrolling() throws {
        add(40)
        try scroll(by: 0)
        settle()
        XCTAssertFalse(try pillShows())
    }

    // MARK: -

    private func add(_ count: Int) {
        let first = model.captions.count
        model.captions += (first..<first + count).map {
            Caption(id: $0, japanese: "字幕 \($0)", ruby: [], english: "")
        }
        settle()
    }

    /// Long enough for a scroll's animation to end.
    private func settle() {
        for _ in 0..<5 { pump() }
    }

    private func scrollView() throws -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(TestScreen.wait { self.window.contentView.flatMap(find) }, "no scroll view")
    }

    private func offset() throws -> CGFloat {
        try scrollView().contentView.bounds.origin.y
    }

    /// The offset with the list's end in sight.
    private func end() throws -> CGFloat {
        let scrollView = try scrollView()
        return try XCTUnwrap(scrollView.documentView).frame.height - scrollView.contentView.bounds.height
    }

    /// Where the pill is, from the window's top left: over the foot of the
    /// list, in the middle.
    private static let pillSpot = CGPoint(x: 200, y: 275)

    /// Whether the pill is drawn. It is no view of its own to be found, so
    /// this looks for its grey, a little in from its end, where the list
    /// behind it is black.
    private func pillShows() throws -> Bool {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let color = try XCTUnwrap(
            rep.colorAt(x: Int((Self.pillSpot.x - 36) * scale), y: Int(Self.pillSpot.y * scale))?
                .usingColorSpace(.deviceRGB)
        )
        return color.brightnessComponent > 0.1 && color.saturationComponent < 0.1
    }

    /// Whether the splitter's line is drawn at a point from the window's
    /// top left, give or take a point.
    private func isOrange(at point: CGPoint) throws -> Bool {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return (-2...2).contains { dy in
            guard let color = rep.colorAt(x: Int(point.x * scale), y: Int((point.y + CGFloat(dy)) * scale))?
                .usingColorSpace(.deviceRGB) else { return false }
            return color.brightnessComponent > 0.7 && color.saturationComponent > 0.6
                && (0.04...0.14).contains(color.hueComponent)
        }
    }

    /// Whether a gap's splitter line is drawn at a point from the window's
    /// top left, give or take a point: grey on the black list.
    private func isGrey(at point: CGPoint) throws -> Bool {
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return (-2...2).contains { dy in
            guard let color = rep.colorAt(x: Int(point.x * scale), y: Int((point.y + CGFloat(dy)) * scale))?
                .usingColorSpace(.deviceRGB) else { return false }
            return color.brightnessComponent > 0.3 && color.saturationComponent < 0.15
        }
    }

    /// The hover trackers of the gaps under the rows, in order; the rows
    /// here have none of their own.
    private func gapTrackers() throws -> [HoverTracker.TrackerView] {
        func find(_ view: NSView) -> [HoverTracker.TrackerView] {
            ((view as? HoverTracker.TrackerView).map { [$0] } ?? []) + view.subviews.flatMap(find)
        }
        let found = try XCTUnwrap(TestScreen.wait {
            self.window.contentView.map(find).flatMap { $0.isEmpty ? nil : $0 }
        }, "no gap tracker in the window")
        return found.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: 300 - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
    }

    private func click(_ point: CGPoint) {
        // Both before pumping: a button that tracks the mouse in a loop of its
        // own has to find the mouse-up waiting in the queue.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(event(type, at: point, clicks: 1), atStart: false)
        }
        pump()
    }

    /// A turn of the wheel over the list. An event made here belongs to no
    /// window, so it is handed to the scroll view and to the watcher, as
    /// the app would have done with one under the pointer.
    private func scroll(by pixels: Int32) throws {
        let wheel = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
        func find(_ view: NSView) -> ScrollWatcher.WatcherView? {
            (view as? ScrollWatcher.WatcherView) ?? view.subviews.lazy.compactMap(find).first
        }
        let watcher = try XCTUnwrap(TestScreen.wait { self.window.contentView.flatMap(find) }, "no scroll watcher")
        watcher.noticed(event, at: NSPoint(x: 200, y: 150))
        try scrollView().scrollWheel(with: event)
        settle()
    }

    private func clickPill() {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: Self.pillSpot.x, y: 300 - Self.pillSpot.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!, atStart: false)
        }
        settle()
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
