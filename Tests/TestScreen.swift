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

extension TestScreen {
    /// What a lookup in a window's views finds, once it finds anything: a
    /// hosting view builds its hierarchy on the run loop, and one pass is
    /// not always enough for it (a loaded CI runner once had no hover tracker
    /// in a caption row after the pass that set the window up). Pumps the
    /// run loop between tries for up to `seconds`, and none at all when the
    /// views are already there.
    @MainActor
    static func wait<Found>(seconds: TimeInterval = 2, for lookup: () -> Found?) -> Found? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let found = lookup() { return found }
            if Date() >= end { return nil }
            while let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
    }
}
