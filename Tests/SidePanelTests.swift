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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
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
        XCTAssertTrue(controls(view).contains { $0 is NSSegmentedControl }, "no panel tab picker in the window")

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
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
        let field = try XCTUnwrap(fields(try XCTUnwrap(window.contentView)).first, "no question field in the window")
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
