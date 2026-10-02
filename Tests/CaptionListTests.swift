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
    }

    struct Host: View {
        let model: Model

        var body: some View {
            CaptionList(
                captions: model.captions, partialText: model.partial, fontSize: 16, playingID: model.playingID
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
        // Within a few points: a lazy stack shifts a little as it measures
        // what it was only estimating, where the jump was a screenful.
        XCTAssertEqual(try offset(), playing, accuracy: 6)

        model.playingID = 11
        settle()
        XCTAssertEqual(try offset(), playing + 58, accuracy: 6)
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
        XCTAssertEqual(try offset(), away, accuracy: 6)

        clickPill()
        XCTAssertEqual(try offset(), playing + 58, accuracy: 6)
        XCTAssertFalse(try pillShows())
        snapshot("list-returned")
        model.playingID = 12
        settle()
        XCTAssertEqual(try offset(), playing + 116, accuracy: 6)
    }

    func testThePillTakesLiveCaptionsBackToTheEnd() throws {
        add(40)
        try scroll(by: 600)
        let away = try offset()
        XCTAssertLessThan(away, try end() - 300)
        add(5)
        XCTAssertEqual(try offset(), away, accuracy: 6)
        snapshot("list-live-scrolled-away")

        XCTAssertTrue(try pillShows(), "no pill after scrolling away")
        clickPill()
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
        add(5)
        XCTAssertEqual(try offset(), try end(), accuracy: 1)
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
