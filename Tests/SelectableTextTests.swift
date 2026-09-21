import SwiftUI
import XCTest
@testable import LiveTrans

/// Selectable text in a real window, next to a FuriganaText: each offers its
/// selection to the same actions, and gives it up when the other is clicked.
@MainActor
final class SelectableTextTests: XCTestCase {
    @Observable
    final class Model {
        var selection: Range<Int>?
        var lookedUp: [String] = []
    }

    struct Host: View {
        @Bindable var model: Model

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 40)
                    SelectableText("school 学校に行く", size: 20)
                        .frame(height: 30, alignment: .top)
                    FuriganaText(
                        tokens: Furigana.annotate("食べる、学校"), fontSize: 20,
                        selection: $model.selection
                    )
                    Color.clear.frame(height: 300)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            .selectionActions { model.lookedUp.append($0) }
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

    // The text is at y 40...63 and the FuriganaText's base text around y 90,
    // both from x 16.
    //
    // A text view follows the real pointer once the mouse is down, wherever
    // the posted events say it is, so its selections are made by range here;
    // clicking on it is making it the first responder.

    func testJishoButtonLooksUpTheSelection() throws {
        try select(NSRange(location: 0, length: 6))
        snapshot("text-selected")
        // Over the word, above it; against the left edge, which the word is
        // too close to for the button to be centred on it.
        let view = try textView()
        let frame = view.convert(view.bounds, to: nil)
        // The button comes up some updates after the selection, and how many
        // depends on the machine: a CI runner needs more than a laptop does.
        // Until it is there the click lands on nothing, so click until it takes.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            click(x: 45, y: 140 - frame.maxY - 16)
        } while model.lookedUp.isEmpty && Date() < deadline
        XCTAssertEqual(
            model.lookedUp, ["school"],
            "text at \(frame), selected \(view.selectedRange()), first responder \(String(describing: window.firstResponder))"
        )
    }

    func testNoSelectionNoButton() throws {
        try select(NSRange(location: 0, length: 6))
        try select(NSRange(location: 3, length: 0))
        click(x: 45, y: 24)
        XCTAssertEqual(model.lookedUp, [])
    }

    func testClickingTheFuriganaTextEndsTheSelection() throws {
        try select(NSRange(location: 0, length: 6))
        click(x: 50, y: 92, count: 2)
        XCTAssertEqual(model.selection, 0..<3)
        XCTAssertEqual(try textView().selectedRange().length, 0)
        snapshot("furigana-selected")
        // Over 食べる now, and no longer over the word.
        click(x: 45, y: 24)
        XCTAssertEqual(model.lookedUp, [])
    }

    func testClickingTheTextEndsTheFuriganaSelection() throws {
        click(x: 50, y: 92, count: 2)
        XCTAssertEqual(model.selection, 0..<3)
        try select(NSRange(location: 7, length: 2))
        XCTAssertNil(model.selection)
        snapshot("text-selected-after-furigana")
    }

    func testScrollingOverTheTextScrollsTheContainer() throws {
        let view = try textView()
        let scrollView = try XCTUnwrap(view.enclosingScrollView)
        let before = scrollView.contentView.bounds.origin.y
        let wheel = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0
        ))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        pump()
        XCTAssertNotEqual(scrollView.contentView.bounds.origin.y, before)
    }

    private func select(_ range: NSRange) throws {
        let view = try textView()
        window.makeFirstResponder(view)
        view.setSelectedRange(range)
        // The button is a few updates behind the selection.
        pump()
        pump()
    }

    private func textView() throws -> NSTextView {
        func find(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.contentView.flatMap(find))
    }

    private func click(x: CGFloat, y: CGFloat, count: Int = 1) {
        gesture((1...count).flatMap { _ in [(.leftMouseDown, x, y), (.leftMouseUp, x, y)] })
    }

    /// All of it posted before any of it is handled: a text view follows the
    /// mouse in a loop of its own from the mouse-down on, and has to find the
    /// rest waiting in the queue.
    private func gesture(_ events: [(NSEvent.EventType, CGFloat, CGFloat)]) {
        var clicks = 0
        for (type, x, y) in events {
            if type == .leftMouseDown { clicks += 1 }
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 140 - y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
            NSApp.postEvent(event, atStart: false)
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
