import SwiftUI
import XCTest
@testable import LiveTrans

/// A dev-mode caption's row with the other recognizers' lines under its
/// own: each line's analysis button at the row's trailing end, one above
/// the other, each analysing its own line.
@MainActor
final class CaptionRowOthersTests: XCTestCase {
    @Observable
    final class Model {
        var selection: Range<Int>?
        var analyzed: [String] = []
    }

    struct Host: View {
        @Bindable var model: Model

        var body: some View {
            let moment = VideoMoment(tabID: 1, url: "https://example.tv/", seconds: 754.6)
            let line = { (id: Int, text: String) in
                Caption(id: id, japanese: text, ruby: Furigana.annotate(text), english: "", moment: moment)
            }
            CaptionRow(
                caption: Caption(
                    id: 0, japanese: "明日は雨が降るらしい", ruby: Furigana.annotate("明日は雨が降るらしい"),
                    english: "It may rain tomorrow.", moment: moment
                ),
                showFurigana: false, fontSize: 20, isAnalyzed: false,
                selection: $model.selection, onAnalyze: { model.analyzed.append("k2") },
                onSeek: {},
                others: [
                    ("nemo", line(-1, "明日は雨が降るらしい。")),
                    ("qwen", line(-2, "明日、雨が降るらしい。")),
                    ("vv", line(-3, "明日は飴が降るらしい")),
                ],
                onAnalyzeOther: { model.analyzed.append($0.japanese) }
            )
            .padding(16)
            .frame(width: 460, height: 220, alignment: .topLeading)
            .background(Color.black)
            .preferredColorScheme(.dark)
        }
    }

    private let model = Model()
    private var window: NSWindow!

    override func setUp() async throws {
        window = TestScreen.window(width: 460, height: 220)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFrontRegardless()
        pump()
    }

    override func tearDown() async throws {
        window.close()
    }

    func testEachLinesButtonIsAtTheRowsEndAndAnalysesItsLine() throws {
        let tracker = try XCTUnwrap(TestScreen.wait { window.contentView.flatMap(Self.find) })
        tracker.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: 200, y: 60)))
        pump()
        snapshot("row-others-hovered")
        // One above the other at the trailing end, level with each line.
        for y in [28.0, 56.0, 84.0, 112.0] {
            click(CGPoint(x: 434, y: y))
        }
        XCTAssertEqual(model.analyzed, ["k2", "明日は雨が降るらしい。", "明日、雨が降るらしい。", "明日は飴が降るらしい"])
    }

    private static func find(in view: NSView) -> HoverTracker.TrackerView? {
        (view as? HoverTracker.TrackerView) ?? view.subviews.lazy.compactMap(find).first
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: 220 - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
    }

    private func click(_ point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(event(type, at: point, clicks: 1), atStart: false)
        }
        pump()
        RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
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
