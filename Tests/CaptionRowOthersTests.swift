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
        var picked: String?
        var seeks = 0
    }

    struct Host: View {
        @Bindable var model: Model

        var body: some View {
            let moment = VideoMoment(tabID: 1, url: "https://example.tv/", seconds: 754.6)
            let line = { (id: Int, text: String, english: String) in
                Caption(id: id, japanese: text, ruby: Furigana.annotate(text), english: english, moment: moment)
            }
            CaptionRow(
                caption: Caption(
                    id: 0, japanese: "明日は雨が降るらしい", ruby: Furigana.annotate("明日は雨が降るらしい"),
                    english: "It may rain tomorrow.", moment: moment
                ),
                showFurigana: false, fontSize: 20, isAnalyzed: false,
                selection: $model.selection, onAnalyze: { model.analyzed.append("k2") },
                onSeek: { model.seeks += 1 },
                others: [
                    ("nemo", line(-1, "明日は雨が降るらしい。", "Nemo says rain.")),
                    ("qwen", line(-2, "明日、雨が降るらしい。", "Qwen says rain.")),
                    ("vv", line(-3, "明日は飴が降るらしい", "")),
                ],
                onAnalyzeOther: { model.analyzed.append($0.japanese) },
                picked: model.picked,
                onPick: { model.picked = $0 }
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

    func testANamePicksItsLineAndAgainBringsTheOthersBack() throws {
        let tracker = try XCTUnwrap(TestScreen.wait { window.contentView.flatMap(Self.find) })
        tracker.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: 200, y: 60)))
        pump()

        click(CGPoint(x: 24, y: 56))
        XCTAssertEqual(model.picked, "nemo")
        XCTAssertEqual(model.seeks, 0, "picking does not play the sentence")
        snapshot("row-others-picked")
        // Alone, it takes the top line.
        click(CGPoint(x: 434, y: 28))
        XCTAssertEqual(model.analyzed, ["明日は雨が降るらしい。"])

        click(CGPoint(x: 24, y: 28))
        XCTAssertNil(model.picked)
        click(CGPoint(x: 434, y: 28))
        XCTAssertEqual(model.analyzed.last, "k2")

        click(CGPoint(x: 24, y: 28))
        XCTAssertEqual(model.picked, "k2")
        click(CGPoint(x: 24, y: 28))
        XCTAssertNil(model.picked)
    }

    func testEachLinesChineseButtonPutsItsTranslationUnderTheRow() throws {
        let tracker = try XCTUnwrap(TestScreen.wait { window.contentView.flatMap(Self.find) })
        tracker.mouseEntered(with: event(.mouseMoved, at: CGPoint(x: 200, y: 60)))
        pump()
        XCTAssertEqual(translation(), "It may rain tomorrow.")
        // vv's line has no Chinese, and no 中: a click after it does nothing.
        click(chineseButton("明日は飴が降るらしい", y: 112))
        XCTAssertEqual(translation(), "It may rain tomorrow.")

        let seeks = model.seeks
        click(chineseButton("明日、雨が降るらしい。", y: 84))
        XCTAssertEqual(translation(), "Qwen says rain.")
        XCTAssertEqual(model.seeks, seeks, "switching does not play the sentence")
        XCTAssertNil(model.picked, "switching hides no line")
        snapshot("row-others-qwen-chinese")
        click(chineseButton("明日は雨が降るらしい。", y: 56))
        XCTAssertEqual(translation(), "Nemo says rain.")
        click(chineseButton("明日は雨が降るらしい", y: 28))
        XCTAssertEqual(translation(), "It may rain tomorrow.")

        // A pick shows its own line's Chinese, with no buttons to switch.
        click(CGPoint(x: 24, y: 84))
        XCTAssertEqual(model.picked, "qwen")
        XCTAssertEqual(translation(), "Qwen says rain.")
        // Alone, its line is at the top, with no 中 after it.
        click(chineseButton("明日、雨が降るらしい。", y: 28))
        XCTAssertEqual(translation(), "Qwen says rain.")
        XCTAssertEqual(model.picked, "qwen")
    }

    /// The text under the lines: the Chinese, here English stand-ins.
    private func translation() -> String? {
        func find(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)?.string
    }

    /// Where the 中 after a line of `japanese` is, in the window's top-left
    /// points: past the row's padding, the name and the text. (SwiftUI shows
    /// no accessibility tree in the test process to find it by.)
    private func chineseButton(_ japanese: String, y: CGFloat) -> CGPoint {
        let text = NSAttributedString(string: japanese, attributes: [.font: NSFont.systemFont(ofSize: 20)])
        return CGPoint(x: 16 + 20 * 1.6 + 6 + text.size().width + 6 + 8, y: y + 4)
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
