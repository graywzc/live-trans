import SwiftUI
import XCTest
@testable import LiveTrans

/// The window's level and the header's pin, in real windows.
@MainActor
final class KeepOnTopTests: XCTestCase {
    private var window: NSWindow!
    private var defaults: UserDefaults!

    private static let size = CGSize(width: 60, height: 60)

    /// What the window does with the setting, as `ContentView` wires it.
    private struct PinnedWindow: View {
        @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false

        var body: some View {
            KeepOnTopButton()
                .frame(width: KeepOnTopTests.size.width, height: KeepOnTopTests.size.height)
                .background(WindowLevel(floating: keepOnTop))
        }
    }

    override func setUp() async throws {
        let suite = "KeepOnTopTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    func testThePinTakesTheWindowInAndOutOfTheFront() throws {
        window = TestScreen.window(size: Self.size)
        window.contentView = NSHostingView(rootView: PinnedWindow().defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        pump()
        waitFor(.normal, "off until asked for")

        try click()
        waitFor(.floating, "the pin floats the window")
        XCTAssertTrue(defaults.bool(forKey: AppSettings.keepOnTop), "kept for the next launch")
        try click()
        waitFor(.normal, "and lets it go again")
        XCTAssertFalse(defaults.bool(forKey: AppSettings.keepOnTop))
    }

    /// The real window follows the setting whichever control changes it, and
    /// shows the pin in the header both ways.
    func testTheCaptionWindowFollowsTheSetting() {
        let engine = CaptionEngine()
        let video = ChromeVideo()
        let root = ContentView()
            .environment(engine)
            .environment(JishoBrowser())
            .environment(SentenceAnalyzer(makeClient: { nil }))
            .environment(SidePanel())
            .environment(video)
            .environment(Prefetcher(engine: engine, video: video))
            .environment(DevPipeline(engine: engine, video: video))
            .environment(ActivityLog())
            .defaultAppStorage(defaults)
        window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        waitFor(.normal, "other windows may cover it by default")
        snapshot("header-pin-off")

        defaults.set(true, forKey: AppSettings.keepOnTop)
        waitFor(.floating, "the setting floats the window")
        snapshot("header-pin-on")
        defaults.set(false, forKey: AppSettings.keepOnTop)
        waitFor(.normal, "and lets it go again")
    }

    private func waitFor(_ level: NSWindow.Level, _ message: String) {
        XCTAssertNotNil(TestScreen.wait { window.level == level ? true : nil }, message)
    }

    private func click() throws {
        let middle = NSPoint(x: Self.size.width / 2, y: Self.size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: middle, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )), atStart: false)
        }
        pump()
    }

    private func pump() {
        while let event = NSApp.nextEvent(
            matching: .any, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true
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
