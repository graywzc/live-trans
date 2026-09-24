import SwiftUI
import XCTest
@testable import LiveTrans

/// The analysis button of a caption: hidden until the pointer is over the row,
/// then a real button.
@MainActor
final class CaptionRowTests: XCTestCase {
    @Observable
    final class Model {
        var selection: Range<Int>?
        var analyzed = 0
        var sought = 0
    }

    struct Host: View {
        @Bindable var model: Model

        var body: some View {
            let japanese = "昨日は忙しくて、昼ご飯を食べられなかった。"
            CaptionRow(
                caption: Caption(
                    id: 0, japanese: japanese, ruby: Furigana.annotate(japanese), english: "I was too busy for lunch.",
                    moment: VideoMoment(tabID: 1, url: "https://example.tv/", seconds: 754.6)
                ),
                showFurigana: true, fontSize: 20, isAnalyzed: false,
                selection: $model.selection, onAnalyze: { model.analyzed += 1 },
                onSeek: { model.sought += 1 }
            )
            .padding(16)
            .frame(width: 400, height: 140, alignment: .topLeading)
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }

    private let model = Model()
    private var window: NSWindow!

    override func setUp() async throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFrontRegardless()
        pump()
    }

    override func tearDown() async throws {
        window.close()
    }

    func testButtonAppearsUnderThePointerAndAnalyzes() throws {
        let tracker = try XCTUnwrap(hoverTracker(in: window.contentView!))
        // Works with another app in front, where the captions usually are.
        XCTAssertEqual(tracker.trackingAreas.count, 1)
        XCTAssertTrue(tracker.trackingAreas[0].options.contains(.activeAlways))
        // The whole row, not only the text in it.
        XCTAssertEqual(tracker.frame.width, 368, accuracy: 1)

        // At the row's trailing end, level with the Japanese.
        let button = CGPoint(x: 374, y: 38)
        snapshot("row-idle")
        click(button)
        XCTAssertEqual(model.analyzed, 0, "hidden, the button must not take clicks")

        tracker.mouseEntered(with: event(.mouseMoved, at: button))
        pump()
        snapshot("row-hovered")
        click(button)
        XCTAssertEqual(model.analyzed, 1)

        tracker.mouseExited(with: event(.mouseMoved, at: button))
        pump()
        click(button)
        XCTAssertEqual(model.analyzed, 1)
    }

    func testTimeIsShownAndPlaysFromTheSentence() {
        snapshot("row-time")
        // Beside the analysis button, level with the Japanese, shown without
        // hovering.
        click(CGPoint(x: 342, y: 42))
        XCTAssertEqual(model.sought, 1)
        XCTAssertEqual(model.analyzed, 0)
    }

    private func hoverTracker(in view: NSView) -> HoverTracker.TrackerView? {
        if let tracker = view as? HoverTracker.TrackerView { return tracker }
        return view.subviews.lazy.compactMap(hoverTracker).first
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: 140 - point.y), modifierFlags: [],
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
