import SwiftUI

@main
struct LiveTransApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        AppSettings.registerDefaults()
        // Captions are echoed to stdout; line-buffer it so they show up live
        // when piped or redirected.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        Window("LiveTrans", id: "captions") {
            ContentView()
                .environment(delegate.engine)
                .task {
                    if UserDefaults.standard.bool(forKey: AppSettings.autoStart) {
                        delegate.engine.start()
                    }
                }
        }
        .defaultSize(width: 900, height: 520)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = CaptionEngine()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting mid-session must still release the GPU. Hold the quit until
    /// /shutdown has been sent.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.isRunning else { return .terminateNow }
        let release = engine.stop()
        Task {
            await release.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
