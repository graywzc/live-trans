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
                .environment(delegate.jisho)
                .environment(delegate.analyzer)
                .environment(delegate.panel)
                .environment(delegate.video)
                .environment(delegate.prefetcher)
                .environment(delegate.activity)
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
    let jisho = JishoBrowser()
    let analyzer = SentenceAnalyzer()
    let panel = SidePanel()
    let video = ChromeVideo()
    let activity = ActivityLog.shared
    let prefetcher: Prefetcher

    override init() {
        // Left by a copy that did not quit cleanly, or by one from before
        // nothing was kept.
        SessionTraces.erase()
        prefetcher = Prefetcher(engine: engine, video: video)
        super.init()
        engine.videoClock = { [video] in await video.moment(at: $0) }
        prefetcher.start()
        activity.follow { [engine] in engine.client }
        panel.applyLaunchArgument()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting mid-session must still release the GPU. Hold the quit until
    /// /shutdown has been sent.
    func applicationWillTerminate(_ notification: Notification) {
        SessionTraces.erase()
    }

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
