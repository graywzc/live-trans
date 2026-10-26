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
                .environment(delegate.devPipeline)
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
    private var windowObserver: NSObjectProtocol?
    let engine = CaptionEngine()
    let jisho = JishoBrowser()
    let analyzer = SentenceAnalyzer()
    let panel = SidePanel()
    let video = ChromeVideo()
    let activity = ActivityLog.shared
    let prefetcher: Prefetcher
    let devPipeline: DevPipeline

    override init() {
        // Left by a copy that did not quit cleanly, or by one from before
        // nothing was kept.
        SessionTraces.erase()
        prefetcher = Prefetcher(engine: engine, video: video)
        devPipeline = DevPipeline(engine: engine, video: video)
        super.init()
        engine.videoClock = { [video] in await video.moment(at: $0) }
        prefetcher.start()
        devPipeline.start()
        prefetcher.isDev = { [panel] in panel.isDev }
        devPipeline.isDev = { [panel] in panel.isDev }
        panel.onDevChange = { [activity, engine, video] isDev in
            activity.isEnabled = isDev
            // In dev mode the host fetches the video itself: the Mac's audio
            // is not heard, and the sound output is left alone. Nor, for now,
            // in production (AppSettings.listenToMacInProduction).
            engine.listensToMac = Self.listensToMac(isDev: isDev)
            if !isDev { video.forgetKeptTab() }
        }
        engine.keepsServerLog = { [panel] in panel.isDev }
        video.keepsTab = { [panel] in panel.isDev }
        activity.follow { [engine] in engine.client }
        panel.restoreMode()
        engine.listensToMac = Self.listensToMac(isDev: panel.isDev)
        video.remember()
        panel.applyLaunchArgument()
    }

    static func listensToMac(isDev: Bool) -> Bool {
        !isDev && UserDefaults.standard.bool(forKey: AppSettings.listenToMacInProduction)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting mid-session must still release the GPU. Hold the quit until
    /// /shutdown has been sent.
    func applicationWillTerminate(_ notification: Notification) {
        SessionTraces.erase()
    }

    /// No window is kept by macOS to restore: what it would keep of them
    /// outlives the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        SessionTraces.erase()
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { note in
            (note.object as? NSWindow)?.isRestorable = false
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
