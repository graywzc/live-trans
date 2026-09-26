import SwiftUI
import XCTest
@testable import LiveTrans

@MainActor
final class SidePanelTests: XCTestCase {
    private func defaults(sidePanel: String?) -> UserDefaults {
        let suite = "SidePanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if let sidePanel { defaults.set(sidePanel, forKey: "sidePanel") }
        return defaults
    }

    func testStartsOpenOnJishoWithoutTheArgument() {
        let panel = SidePanel()
        panel.applyLaunchArgument(defaults: defaults(sidePanel: nil))
        XCTAssertTrue(panel.isPresented)
        XCTAssertEqual(panel.tab, .jisho)
    }

    func testClosedStartsWithTheCaptionsAlone() {
        let panel = SidePanel()
        panel.applyLaunchArgument(defaults: defaults(sidePanel: "closed"))
        XCTAssertFalse(panel.isPresented)
    }

    func testTheArgumentOpensTheNamedTab() {
        let jisho = SidePanel()
        jisho.applyLaunchArgument(defaults: defaults(sidePanel: "jisho"))
        XCTAssertTrue(jisho.isPresented)
        XCTAssertEqual(jisho.tab, .jisho)

        let analysis = SidePanel()
        analysis.applyLaunchArgument(defaults: defaults(sidePanel: "analysis"))
        XCTAssertTrue(analysis.isPresented)
        XCTAssertEqual(analysis.tab, .analysis)
    }

    func testAnUnknownValueIsIgnored() {
        let panel = SidePanel()
        panel.applyLaunchArgument(defaults: defaults(sidePanel: "both"))
        XCTAssertTrue(panel.isPresented)
        XCTAssertEqual(panel.tab, .jisho)
    }
}

/// The whole window as an ordinary launch leaves it: captions on the left,
/// the panel on the right, from the first frame, with no argument given.
@MainActor
final class SidePanelLaunchSnapshotTests: XCTestCase {
    func testTheWindowOpensWithBothHalves() throws {
        let suite = "SidePanelLaunchSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let panel = SidePanel()
        panel.applyLaunchArgument(defaults: defaults)

        let root = ContentView()
            .environment(CaptionEngine())
            .environment(JishoBrowser())
            .environment(SentenceAnalyzer(makeClient: { nil }))
            .environment(panel)
            .environment(ChromeVideo())
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<3 {
            while let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }

        let view = try XCTUnwrap(window.contentView)
        // The panel's tab picker and close button are real controls in the
        // hierarchy only while the panel is open.
        func controls(_ v: NSView) -> [NSControl] {
            (v as? NSControl).map { [$0] } ?? [] + v.subviews.flatMap(controls)
        }
        XCTAssertNotNil(
            TestScreen.wait { controls(view).first { $0 is NSSegmentedControl } }, "no panel tab picker in the window"
        )

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/launch-both-panels.png"))
        }
    }
}

/// The question field in the real window: Control-C takes the cursor out of
/// it, so that Space is the video's again.
@MainActor
final class QuestionFieldControlCTests: XCTestCase {
    func testControlCLeavesTheQuestionField() throws {
        let panel = SidePanel()
        panel.show(.analysis)
        let analyzer = SentenceAnalyzer(makeClient: { nil })
        analyzer.analyze(Caption(id: 1, japanese: "最初", ruby: [], english: ""))

        let root = ContentView()
            .environment(CaptionEngine())
            .environment(JishoBrowser())
            .environment(analyzer)
            .environment(panel)
            .environment(ChromeVideo())
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }
        func pump() {
            for _ in 0..<3 {
                while let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true
                ) {
                    NSApp.sendEvent(event)
                }
            }
        }
        pump()

        func fields(_ v: NSView) -> [NSTextField] {
            ((v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + v.subviews.flatMap(fields)
        }
        let view = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(TestScreen.wait { fields(view).first }, "no question field in the window")
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")

        let controlC = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{03}",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        NSApp.postEvent(controlC, atStart: false)
        pump()
        XCTAssertFalse(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")
    }
}

/// At launch the Jisho page is in front, and its search box asks for the
/// cursor as it loads. Space is still the video's until the page is clicked.
@MainActor
final class LaunchFocusTests: XCTestCase {
    func testThePageHasTheCursorOnlyOnceClicked() throws {
        let panel = SidePanel()
        let browser = JishoBrowser()
        // Stands in for jisho.org, whose home page focuses its search box.
        browser.webView.loadHTMLString("<input id=q autofocus>", baseURL: nil)

        let root = ContentView()
            .environment(CaptionEngine())
            .environment(browser)
            .environment(SentenceAnalyzer(makeClient: { nil }))
            .environment(panel)
            .environment(ChromeVideo())
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func pump(seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true
                ) {
                    NSApp.sendEvent(event)
                }
            }
        }
        pump(seconds: 0.5)
        XCTAssertFalse(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")
        let end = Date().addingTimeInterval(5)
        while browser.isLoading, Date() < end { pump(seconds: 0.2) }
        pump(seconds: 1)
        XCTAssertFalse(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")

        // As WebKit does when the page's script focuses a box: refused.
        window.makeFirstResponder(browser.webView)
        XCTAssertFalse(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")

        // A click into the page is the one way in. The test host is not the
        // active app, so the window is never made key, and a click into a
        // window that is not key is spent on bringing it to the front.
        window.becomeKey()
        let web = browser.webView
        let inWindow = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            NSApp.postEvent(click, atStart: false)
        }
        pump(seconds: 0.5)
        XCTAssertTrue(SpaceKey.typesSpace(window.firstResponder), "\(String(describing: window.firstResponder))")
    }
}
