import SwiftUI
import XCTest
@testable import LiveTrans

/// What the host is running, right of the Start button, in real windows:
/// listed when it fits, a click away when it does not.
@MainActor
final class RunningStatusTests: XCTestCase {
    private var window: NSWindow!

    private static let height: CGFloat = 48
    private static let many = ["Audio download", "k2 captioning", "Speaker detection", "nemo captioning"]

    override func tearDown() async throws {
        // Shut the way a person shuts it, with a click beside it. Closing
        // only its window seems to leave the popover open as far as AppKit
        // knows, so on a slow runner the next test's click went to closing it.
        if window != nil, !popovers().isEmpty {
            try click(atX: 4)
            _ = TestScreen.wait { self.popovers().isEmpty ? true : nil }
        }
        for popover in popovers() { popover.close() }
        window?.close()
        window = nil
    }

    func testWhatFitsIsListedAndNeedsNoClick() throws {
        show(["Audio download", "k2 captioning"], width: 320)
        snapshot("running-listed")
        try click()
        XCTAssertTrue(popovers().isEmpty, "all of it is in sight already")
    }

    func testMoreThanFitsOpensTheWholeListOnAClick() throws {
        show(Self.many, width: 320)
        snapshot("running-summary")
        try click()
        XCTAssertNotNil(TestScreen.wait { self.popovers().first }, "the whole list opens; windows: \(Self.windows())")
        snapshot("running-summary-open")
    }

    func testANarrowRowStillOpensTheList() throws {
        show(Self.many, width: 110)
        snapshot("running-count")
        try click()
        XCTAssertNotNil(TestScreen.wait { self.popovers().first }, "the whole list opens; windows: \(Self.windows())")
    }

    func testNothingRunningShowsNothing() {
        show([], width: 320)
        let size = NSHostingView(rootView: RunningStatus(items: [])).fittingSize
        XCTAssertLessThanOrEqual(size.height, 1, "an empty slot, as before")
    }

    /// Each task with a place on the video's bar is marked as it is drawn
    /// there, so its color can be told; the others keep the room empty.
    func testEachTaskIsMarkedInItsColorOnTheBar() {
        XCTAssertEqual(RunningStatus.mark(for: "k2 captioning"), .init(color: VideoBar.color(of: "k2"), thick: true))
        XCTAssertEqual(
            RunningStatus.mark(for: "Translating nemo captions"), .init(color: VideoBar.translatedColor(of: "nemo"), thick: false)
        )
        XCTAssertEqual(RunningStatus.mark(for: "Audio download"), .init(color: VideoBar.fetchedColor, thick: true))
        XCTAssertEqual(RunningStatus.mark(for: "Speaker detection")?.dashed, true)
        XCTAssertNil(RunningStatus.mark(for: "Whisper words"))
        show(["k2 captioning", "Translating qwen captions"], width: 320)
        snapshot("running-colored")
        XCTAssertTrue(hasPixel { $0.blueComponent > $0.redComponent + 0.3 }, "k2's blue")
        XCTAssertTrue(hasPixel { $0.redComponent > $0.blueComponent + 0.15 && $0.redComponent > 0.3 }, "qwen's pink")
    }

    private func hasPixel(_ test: (NSColor) -> Bool) -> Bool {
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), test(color) { return true }
            }
        }
        return false
    }

    private func show(_ items: [String], width: CGFloat) {
        XCTAssertNotNil(TestScreen.wait { self.popovers().isEmpty ? true : nil }, "a popover left from before: \(Self.windows())")
        window = TestScreen.window(width: width, height: Self.height)
        window.contentView = NSHostingView(
            rootView: RunningStatus(items: items)
                .padding(.trailing, 8)
                .frame(width: width, height: Self.height)
                .background(Color.black)
                .preferredColorScheme(.dark)
        )
        window.makeKeyAndOrderFront(nil)
        pump()
    }

    /// At the row's right end, where the status sits, or at `x`; the
    /// pointer moved there first, as a real one would be.
    private func click(atX x: CGFloat? = nil) throws {
        let point = NSPoint(x: x ?? window.frame.width - 24, y: Self.height / 2)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1
            )), atStart: false)
        }
        pump()
    }

    private static func windows() -> String {
        NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" }.joined(separator: ", ")
    }

    private func popovers() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private func pump() {
        while let event = NSApp.nextEvent(
            matching: .any, until: Date().addingTimeInterval(0.3), inMode: .default, dequeue: true
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
