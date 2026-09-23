import SwiftUI
import XCTest
@testable import LiveTrans

/// The real view in a real window, driven by mouse events: what the geometry
/// tests can't show is whether the events arrive at all.
@MainActor
final class SelectionInteractionTests: XCTestCase {
    @Observable
    final class Model {
        var selection: Range<Int>?
        var lookedUp: [String] = []
        var grammar: [String] = []
    }

    struct Host: View {
        @Bindable var model: Model

        // As the captions are laid out: a row of a lazy stack in a scroll
        // view, under another row whose text takes clicks of its own. The
        // actions float over that row.
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("The caption before")
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .frame(height: 60)
                    FuriganaText(
                        tokens: Furigana.annotate("食べる、学校"), fontSize: 20,
                        selection: $model.selection
                    )
                }
                .padding(.horizontal, 16)
            }
            .selectionActions(onLookUp: { model.lookedUp.append($0) }, onGrammar: { model.grammar.append($0) })
            .foregroundStyle(.white)
            .frame(width: 400, height: 140)
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

    // The base text starts at x 16; its row is below the 60 of the row before
    // and the reading row, so y 82 is inside it. Kana and kanji are about 19 wide and
    // the comma half that, which puts 学校 at x 84...122.

    func testDoubleClickSelectsTheWholeWord() {
        click(x: 50, y: 82, count: 2)
        XCTAssertEqual(model.selection, 0..<3)
    }

    func testDragSelectsCharacters() {
        mouse(.leftMouseDown, x: 37, y: 82)
        mouse(.leftMouseDragged, x: 60, y: 82)
        mouse(.leftMouseDragged, x: 104, y: 82)
        mouse(.leftMouseUp, x: 104, y: 82)
        XCTAssertEqual(model.selection, 1..<5)
    }

    func testClickDismissesTheSelection() {
        click(x: 50, y: 82, count: 2)
        click(x: 110, y: 82)
        XCTAssertNil(model.selection)
    }

    func testJishoButtonLooksUpTheSelection() {
        click(x: 110, y: 82, count: 2)
        XCTAssertEqual(model.selection, 4..<6)
        snapshot("selected")
        // On "Jisho", at the pill's left end.
        click(x: 55, y: 44)
        XCTAssertEqual(model.lookedUp, ["学校"])
    }

    func testGrammarButtonAsksAboutTheSelection() {
        click(x: 110, y: 82, count: 2)
        snapshot("grammar")
        // Between Jisho and Copy.
        click(x: 125, y: 44)
        XCTAssertEqual(model.grammar, ["学校"])
        XCTAssertTrue(model.lookedUp.isEmpty)
    }

    private func click(x: CGFloat, y: CGFloat, count: Int = 1) {
        for clicks in 1...count {
            mouse(.leftMouseDown, x: x, y: y, clicks: clicks)
            mouse(.leftMouseUp, x: x, y: y, clicks: clicks)
        }
    }

    /// Posted rather than sent: a SwiftUI button tracks the mouse in a loop of
    /// its own, which has to find the mouse-up waiting in the queue.
    private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 140 - y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        )!
        NSApp.postEvent(event, atStart: false)
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
