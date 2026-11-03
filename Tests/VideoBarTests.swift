import SwiftUI
import XCTest
@testable import LiveTrans

/// The video's bar in a real window, dragged with real mouse events.
@MainActor
final class VideoBarTests: XCTestCase {
    private var window: NSWindow!
    private var sought: [Double] = []

    private static let size = CGSize(width: 480, height: 60)
    /// The bar sits at the foot of the window, leaving room above it for
    /// the pointer's time.
    private static let barY: CGFloat = 44

    override func setUp() async throws {
        sought = []
        window = TestScreen.window(size: Self.size)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func show(
        duration: Double?, playhead: Double? = 300, captioned: [ClosedRange<Double>] = [240...600, 0...120],
        fetched: ClosedRange<Double>? = 240...900, reached: [(label: String, seconds: Double)] = [],
        translated: [(label: String, seconds: Double)] = [], speakers: DevPipeline.SpeakerState? = nil
    ) {
        let bar = VideoBar(
            duration: duration, playhead: playhead, captioned: captioned, fetched: fetched, reached: reached,
            translated: translated, speakers: speakers
        ) { [unowned self] in sought.append($0) }
        window.contentView = NSHostingView(
            rootView: bar.padding(.horizontal, 12).padding(.bottom, 8)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
                .background(Color.black)
        )
        window.makeKeyAndOrderFront(nil)
        pump()
    }

    /// Where the track starts and ends in the window. It lies between the
    /// two times, whose widths the font decides, so it is worked out from
    /// two presses 60 points apart and the places in the video they gave.
    private func trackEnds() throws -> (left: CGFloat, right: CGFloat) {
        var places: [Double] = []
        for x in [240.0, 300.0] {
            drag(from: CGPoint(x: x, y: Self.barY), to: CGPoint(x: x, y: Self.barY))
            places.append(try XCTUnwrap(sought.last, "a press on the bar seeks"))
        }
        sought = []
        let perPoint = (places[1] - places[0]) / 60
        let left = 240 - CGFloat(places[0] / perPoint)
        return (left, left + CGFloat(1200 / perPoint))
    }

    func testDroppingTheThumbSeeksOnceToWhereItWasDropped() throws {
        show(duration: 1200)
        let track = try trackEnds()
        XCTAssertGreaterThan(track.left, 12, "the track starts after the time")
        XCTAssertLessThan(track.right, Self.size.width - 12)
        let quarter = track.left + (track.right - track.left) / 4
        let threeQuarters = track.left + (track.right - track.left) * 3 / 4
        drag(from: CGPoint(x: quarter, y: Self.barY), to: CGPoint(x: threeQuarters, y: Self.barY))
        // Not while it is dragged, only where it lands.
        XCTAssertEqual(sought.count, 1)
        XCTAssertEqual(try XCTUnwrap(sought.first), 900, accuracy: 3)
        snapshot("video-bar")
    }

    func testDraggedOffTheEndItStopsAtTheEnd() throws {
        show(duration: 1200)
        let track = try trackEnds()
        drag(from: CGPoint(x: (track.left + track.right) / 2, y: Self.barY), to: CGPoint(x: Self.size.width + 200, y: Self.barY))
        XCTAssertEqual(sought, [1200])
        drag(from: CGPoint(x: (track.left + track.right) / 2, y: Self.barY), to: CGPoint(x: -50, y: Self.barY))
        XCTAssertEqual(sought, [1200, 0])
    }

    func testTheTimeUnderThePointerFloatsAboveTheBar() throws {
        show(duration: 1200)
        let aboveBar = CGRect(x: 0, y: 0, width: Self.size.width, height: Self.barY - 10)
        XCTAssertFalse(isLit(aboveBar), "nothing above the bar until the pointer comes")
        let track = try trackEnds()
        // Measuring the track pressed it, and the time stays over the
        // pointer after a press until the pointer leaves.
        let view = try dragView()
        view.mouseExited(with: event(.mouseMoved, at: CGPoint(x: 300, y: Self.barY)))
        pump()
        XCTAssertFalse(isLit(aboveBar), "the time should go with the pointer")
        let x = track.left + (track.right - track.left) * 3 / 4
        // The bar's track is 16 high about barY, and the time floats
        // VideoBar.labelRise above that, centred on the pointer.
        let above = CGRect(
            x: x - VideoBar.labelSize.width / 2, y: Self.barY - 8 - VideoBar.labelRise - VideoBar.labelSize.height,
            width: VideoBar.labelSize.width, height: VideoBar.labelSize.height
        )
        view.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: x, y: Self.barY)))
        pump()
        XCTAssertTrue(isLit(above), "no time over the pointer")
        // Only there: not where the press was.
        XCTAssertFalse(isLit(CGRect(x: 0, y: 0, width: above.minX - 1, height: Self.barY - 10)))
        snapshot("video-bar-hovered")
        view.mouseExited(with: event(.mouseMoved, at: CGPoint(x: x, y: Self.barY)))
        pump()
        XCTAssertFalse(isLit(aboveBar))
    }

    func testAVideoWithNoEndShowsNoTimeUnderThePointer() throws {
        show(duration: nil)
        let view = try dragView()
        view.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: 300, y: Self.barY)))
        pump()
        XCTAssertFalse(isLit(CGRect(x: 276, y: Self.barY - 8 - VideoBar.labelRise - 16, width: 48, height: 16)))
        XCTAssertFalse(isLit(CGRect(x: 0, y: 0, width: Self.size.width, height: Self.barY - 10)), "nothing above the bar")
    }

    func testAVideoWithNoEndCannotBeDragged() {
        show(duration: nil)
        drag(from: CGPoint(x: 200, y: Self.barY), to: CGPoint(x: 300, y: Self.barY))
        XCTAssertEqual(sought, [])
    }

    /// In Default each recognizer's reach has its own color from the start,
    /// the one furthest behind on top, and the fetched audio past them grey.
    func testEachRecognizerShowsHowFarItHasCaptionedInItsOwnColor() throws {
        show(
            duration: 1200, playhead: nil, captioned: [], fetched: 0...1050,
            reached: [("k2", 900), ("nemo", 600), ("qwen", 300)]
        )
        let track = try trackEnds()
        func at(_ seconds: Double) throws -> NSColor {
            let x = track.left + (track.right - track.left) * CGFloat(seconds / 1200)
            return try XCTUnwrap(pixel(at: CGPoint(x: x, y: Self.barY)))
        }
        let qwen = try at(150), nemo = try at(450), k2 = try at(750), fetched = try at(1000), empty = try at(1150)
        XCTAssertGreaterThan(k2.blueComponent, k2.redComponent + 0.2, "k2 is blue")
        XCTAssertGreaterThan(nemo.blueComponent, 0.3, "nemo is purple")
        XCTAssertGreaterThan(nemo.redComponent, 0.3, "nemo is purple")
        XCTAssertGreaterThan(qwen.redComponent, qwen.blueComponent, "qwen is pink")
        for (a, b) in [(qwen, nemo), (nemo, k2), (k2, fetched)] {
            XCTAssertGreaterThan(Self.distance(a, b), 0.15, "each stretch its own color")
        }
        XCTAssertLessThan(abs(fetched.redComponent - fetched.blueComponent), 0.05, "the fetched audio stays grey")
        XCTAssertGreaterThan(fetched.brightnessComponent, empty.brightnessComponent, "brighter than the unfetched track")
        snapshot("video-bar-recognizers")
        // In the help, each with its time.
        XCTAssertEqual(
            VideoBar.summary(duration: 1200, fetched: 1050, reached: [("k2", 900), ("nemo", 600), ("qwen", 300)]),
            "k2 15:00 · nemo 10:00 · qwen 5:00, audio fetched to 17:30 of 20:00"
        )
    }

    /// Under the bar, a lane of how far each one's text is translated, in
    /// its color, and one of the speakers: striped while they are told
    /// apart, whole once they are.
    func testTranslationsAndSpeakersHaveLanesUnderTheBar() throws {
        let reached = [("k2", 900.0), ("nemo", 600.0), ("qwen", 300.0)]
        show(
            duration: 1200, playhead: nil, captioned: [], fetched: 0...1050, reached: reached,
            translated: [("k2", 900), ("nemo", 450), ("qwen", 150)], speakers: .running
        )
        let track = try trackEnds()
        // The bar is 16 high, the lanes 3 each 2 apart under it, all of it
        // standing on the window's foot, 8 above the bottom.
        let foot = Self.size.height - 8
        let bar = foot - 2 * (VideoBar.laneGap + VideoBar.laneHeight) - VideoBar.barHeight / 2
        let translatedLane = foot - VideoBar.laneHeight - VideoBar.laneGap - VideoBar.laneHeight / 2
        let speakersLane = foot - VideoBar.laneHeight / 2
        func at(_ seconds: Double, _ y: CGFloat) throws -> NSColor {
            let x = track.left + (track.right - track.left) * CGFloat(seconds / 1200)
            return try XCTUnwrap(pixel(at: CGPoint(x: x, y: y)))
        }
        XCTAssertGreaterThan(try at(750, bar).blueComponent, 0.5, "the bar keeps its colors")
        // k2 translated to 15:00, nemo to 7:30, qwen to 2:30.
        let qwen = try at(100, translatedLane), nemo = try at(300, translatedLane), k2 = try at(700, translatedLane)
        XCTAssertGreaterThan(k2.blueComponent, k2.redComponent + 0.1, "k2's translations in its blue")
        XCTAssertGreaterThan(qwen.redComponent, qwen.blueComponent, "qwen's in its pink")
        XCTAssertGreaterThan(Self.distance(nemo, k2), 0.1)
        XCTAssertLessThan(Self.distance(try at(1000, translatedLane), try at(1100, translatedLane)), 0.05, "nothing past them")
        // Striped while running: some of the lane lit, some not.
        let lit = stride(from: 0.0, to: 1200, by: 5).map { (try? at($0, speakersLane))?.greenComponent ?? 0 }
        XCTAssertTrue(lit.contains { $0 > 0.3 } && lit.contains { $0 < 0.2 }, "striped while being told apart")
        snapshot("video-bar-lanes")

        show(duration: 1200, playhead: nil, captioned: [], fetched: 0...1050, reached: reached, speakers: .done)
        let whole = stride(from: 20.0, to: 1180, by: 5).map { (try? at($0, speakersLane))?.greenComponent ?? 0 }
        XCTAssertTrue(whole.allSatisfy { $0 > 0.3 }, "whole once told apart")
        XCTAssertEqual(
            VideoBar.summary(
                duration: 1200, fetched: 1050, reached: reached, translated: [("k2", 900), ("nemo", 450), ("qwen", 150)],
                speakers: .running
            ),
            "k2 15:00 · nemo 10:00 · qwen 5:00, audio fetched to 17:30 of 20:00\n"
                + "Translated: k2 15:00 · nemo 7:30 · qwen 2:30\nSpeakers: being told apart"
        )
    }

    func testTheRecognizerFurthestBehindIsDrawnLast() {
        let order = VideoBar.drawingOrder([("k2", 900), ("nemo", 300), ("qwen", 600)]).map(\.label)
        XCTAssertEqual(order, ["k2", "qwen", "nemo"])
        XCTAssertEqual(VideoBar.drawingOrder([("k2", 900), ("nemo", 900), ("qwen", 0)]).map(\.label), ["k2", "nemo", "qwen"])
    }

    private func pixel(at point: CGPoint) -> NSColor? {
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    /// Whether anything light is drawn in `rect`, from the window's top
    /// left: the time's white digits on the black window.
    private func isLit(_ rect: CGRect) -> Bool {
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                if let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB),
                   color.brightnessComponent > 0.5 {
                    return true
                }
            }
        }
        return false
    }

    private func dragView() throws -> VideoBar.BarDrag.DragView {
        func find(in view: NSView) -> VideoBar.BarDrag.DragView? {
            (view as? VideoBar.BarDrag.DragView) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(TestScreen.wait { window.contentView.flatMap(find) }, "no drag view in the window")
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
        NSApp.postEvent(event(.leftMouseDragged, at: end), atStart: false)
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
