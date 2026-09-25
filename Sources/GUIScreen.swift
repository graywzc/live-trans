import AppKit

/// The display named by the GUI_SCREEN environment variable, when one by
/// that name is attached: where windows open during development and tests,
/// so that they stay off the display being worked on. Given to xcodebuild
/// as TEST_RUNNER_GUI_SCREEN, it reaches the tests and the app they run in.
enum GUIScreen {
    static var named: NSScreen? {
        guard let name = ProcessInfo.processInfo.environment["GUI_SCREEN"] else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }
}
