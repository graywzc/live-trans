import AppKit
import XCTest
@testable import LiveTrans

/// With GUI_SCREEN naming a display, the tests' windows and the app's own
/// open on it; on a machine without such a display, nothing to check.
@MainActor
final class TestScreenTests: XCTestCase {
    func testWindowsOpenOnTheNamedDisplay() throws {
        guard let screen = TestScreen.screen else {
            throw XCTSkip("GUI_SCREEN does not name an attached display")
        }
        let window = TestScreen.window(width: 200, height: 100)
        defer { window.close() }
        window.orderFrontRegardless()
        XCTAssertEqual(window.screen?.localizedName, screen.localizedName, "frame \(window.frame)")

        // The app the tests run in opens its captions window at launch.
        let captions = try XCTUnwrap(NSApp.windows.first { $0.title == "LiveTrans" })
        XCTAssertEqual(captions.screen?.localizedName, screen.localizedName, "frame \(captions.frame)")
    }
}
