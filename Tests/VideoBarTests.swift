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

    private func show(duration: Double?, playhead: Double? = 300) {
        let bar = VideoBar(
            duration: duration, playhead: playhead, captioned: [240...600, 0...120], fetched: 240...900
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
        let track = try trackEnds()
        let x = track.left + (track.right - track.left) * 3 / 4
        // The bar's track is 16 high about barY, and the time floats
        // VideoBar.labelRise above that, centred on the pointer.
        let above = CGRect(
            x: x - VideoBar.labelSize.width / 2, y: Self.barY - 8 - VideoBar.labelRise - VideoBar.labelSize.height,
            width: VideoBar.labelSize.width, height: VideoBar.labelSize.height
        )
        XCTAssertFalse(isLit(above))
        let view = try dragView()
        view.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: x, y: Self.barY)))
        pump()
        XCTAssertTrue(isLit(above), "no time over the pointer")
        snapshot("video-bar-hovered")
        view.mouseExited(with: event(.mouseMoved, at: CGPoint(x: x, y: Self.barY)))
        pump()
        XCTAssertFalse(isLit(above), "the time should go with the pointer")
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
