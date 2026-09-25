import AppKit
@testable import LiveTrans

/// The GUI tests' windows. They flash up for the length of the suite, so
/// they open on the display named by GUI_SCREEN (TEST_RUNNER_GUI_SCREEN to
/// xcodebuild), which can be one that nobody is working on; without it, or
/// when no display has that name, on the main one.
enum TestScreen {
    static var screen: NSScreen? { GUIScreen.named }

    /// A titled window with content of this size, not released when closed.
    static func window(width: CGFloat, height: CGFloat) -> NSWindow {
        window(size: CGSize(width: width, height: height))
    }

    static func window(size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // A frame given to init is put back on the main display; one set
        // afterwards stays where it is put.
        if let screen {
            window.setFrameOrigin(screen.visibleFrame.origin)
        }
        return window
    }
}
