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

    func testStartsClosedWithoutTheArgument() {
        let panel = SidePanel()
        panel.openIfRequestedAtLaunch(defaults: defaults(sidePanel: nil))
        XCTAssertFalse(panel.isPresented)
    }

    func testTheArgumentOpensTheNamedTab() {
        let jisho = SidePanel()
        jisho.openIfRequestedAtLaunch(defaults: defaults(sidePanel: "jisho"))
        XCTAssertTrue(jisho.isPresented)
        XCTAssertEqual(jisho.tab, .jisho)

        let analysis = SidePanel()
        analysis.openIfRequestedAtLaunch(defaults: defaults(sidePanel: "analysis"))
        XCTAssertTrue(analysis.isPresented)
        XCTAssertEqual(analysis.tab, .analysis)
    }

    func testAnUnknownValueIsIgnored() {
        let panel = SidePanel()
        panel.openIfRequestedAtLaunch(defaults: defaults(sidePanel: "both"))
        XCTAssertFalse(panel.isPresented)
    }
}

/// The whole window as the launch argument leaves it: captions on the left,
/// the panel on the right, from the first frame.
@MainActor
final class SidePanelLaunchSnapshotTests: XCTestCase {
    func testTheWindowOpensWithBothHalves() throws {
        let suite = "SidePanelLaunchSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("jisho", forKey: "sidePanel")

        let panel = SidePanel()
        panel.openIfRequestedAtLaunch(defaults: defaults)

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
