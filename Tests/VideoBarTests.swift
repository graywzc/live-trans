import SwiftUI
import XCTest
@testable import LiveTrans

/// The video's bar in a real window, dragged with real mouse events.
@MainActor
final class VideoBarTests: XCTestCase {
    private var window: NSWindow!
    private var sought: [Double] = []

    private static let size = CGSize(width: 480, height: 40)

    override func setUp() async throws {
        sought = []
        window = TestScreen.window(size: Self.size)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func show(duration: Double?, playhead: Double? = 300) {
        let bar = VideoBar(
            duration: duration, playhead: playhead, captioned: [240...600, 0...120], fetched: 240...900
        ) { [unowned self] in sought.append($0) }
        window.contentView = NSHostingView(
            rootView: bar.padding(.horizontal, 12).frame(width: Self.size.width, height: Self.size.height)
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
            drag(from: CGPoint(x: x, y: 20), to: CGPoint(x: x, y: 20))
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
        drag(from: CGPoint(x: quarter, y: 20), to: CGPoint(x: threeQuarters, y: 20))
        // Not while it is dragged, only where it lands.
        XCTAssertEqual(sought.count, 1)
        XCTAssertEqual(try XCTUnwrap(sought.first), 900, accuracy: 3)
        snapshot("video-bar")
    }

    func testDraggedOffTheEndItStopsAtTheEnd() throws {
        show(duration: 1200)
        let track = try trackEnds()
        drag(from: CGPoint(x: (track.left + track.right) / 2, y: 20), to: CGPoint(x: Self.size.width + 200, y: 20))
        XCTAssertEqual(sought, [1200])
        drag(from: CGPoint(x: (track.left + track.right) / 2, y: 20), to: CGPoint(x: -50, y: 20))
        XCTAssertEqual(sought, [1200, 0])
    }

    func testAVideoWithNoEndCannotBeDragged() {
        show(duration: nil)
        drag(from: CGPoint(x: 200, y: 20), to: CGPoint(x: 300, y: 20))
        XCTAssertEqual(sought, [])
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
