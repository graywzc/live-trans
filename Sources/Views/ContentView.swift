import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(CaptionEngine.self) private var engine
    @Environment(JishoBrowser.self) private var jisho
    @Environment(SentenceAnalyzer.self) private var analyzer
    @Environment(SidePanel.self) private var panel
    @Environment(ChromeVideo.self) private var video
    @Environment(Prefetcher.self) private var prefetch
    @Environment(DevPipeline.self) private var dev
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false
    @AppStorage(AppSettings.sidePanelWidth) private var panelWidth = 440.0

    /// One selection for the whole window, as in any text view.
    @State private var selection: CaptionSelection?
    @State private var confirmRerun = false

    private static let minCaptionsWidth: CGFloat = 420

    var body: some View {
        // A lookup or an analysis opens beside the captions, which keep
        // coming meanwhile.
        GeometryReader { proxy in
            let widest = max(proxy.size.width - Self.minCaptionsWidth - SplitHandle.width, SidePanelView.minWidth)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    captionList
                    ActivityView()
                    footer
                }
                .frame(minWidth: Self.minCaptionsWidth, maxWidth: .infinity)
                if panel.isPresented {
                    SplitHandle { x in
                        panelWidth = min(max(proxy.size.width - x - SplitHandle.width / 2, SidePanelView.minWidth), widest)
                    }
                    SidePanelView()
                        .frame(width: min(max(panelWidth, SidePanelView.minWidth), widest))
                }
            }
        }
        .frame(
            minWidth: Self.minCaptionsWidth + (panel.isPresented ? SplitHandle.width + SidePanelView.minWidth : 0),
            minHeight: 300
        )
        .background(Color.black.ignoresSafeArea())
        .background(WindowLevel(floating: keepOnTop))
        .preferredColorScheme(.dark)
    }

    /// The header as it fits: whole, or with the mode switch's labels
    /// short and the version left out, on a narrow caption side.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .font(.body)
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            StatusPill(status: engine.status)
            Picker("Mode", selection: Binding(get: { panel.isDev }, set: { panel.isDev = $0 })) {
                Text("Default").tag(true)
                Text("Incognito").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Default runs a step of the pipeline over the whole video and keeps what it finds, for the iPhone too; Incognito captions what you watch and leaves no trace")
            Spacer(minLength: 0)
            OutputPicker()
            VideoControls()
            if !engine.captions.isEmpty {
                Button(role: .destructive) {
                    engine.clear()
                    dev.captionsCleared()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear the captions")
            }
            Button(role: .destructive) {
                AppRelaunch.relaunch(engine: engine)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Clear everything and restart")
            if !compact {
                Text(AppVersion.display)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.gray.opacity(0.7))
                    .help("LiveTrans version")
            }
            KeepOnTopButton()
            SettingsLink {
                Image(systemName: "gearshape")
            }
        }
    }

    private var captionList: some View {
        CaptionList(
            captions: engine.captions, partialText: engine.partialText, fontSize: fontSize,
            playingID: prefetch.playingCaptionID, lull: prefetch.lull
        ) { caption in
            CaptionRow(
                caption: caption, showFurigana: showFurigana, fontSize: fontSize,
                isAnalyzed: panel.isPresented && panel.tab == .analysis
                    && analyzer.hasAnalyzed(caption),
                selection: selectionBinding(for: caption),
                onAnalyze: { analyze(caption) },
                onSeek: caption.moment.map { moment in { video.send(.seek(moment)) } },
                isCurrent: prefetch.currentCaptionID == caption.id,
                official: panel.isDev ? dev.official(for: caption) : nil,
                others: dev.others(for: caption),
                isOtherAnalyzed: { panel.isPresented && panel.tab == .analysis && analyzer.hasAnalyzed($0) },
                onAnalyzeOther: { analyze($0) },
                picked: dev.pickedVersion(for: caption),
                onPick: { dev.pick($0, for: caption) },
                typed: dev.typed(for: caption),
                onType: caption.moment == nil ? nil : { dev.type($0, for: caption) }
            )
        }
        .selectionActions(onLookUp: lookUp)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dev.refreshPicks()
        }
        .overlay {
            if engine.captions.isEmpty, engine.partialText.isEmpty {
                placeholder
            }
        }
    }

    private func selectionBinding(for caption: Caption) -> Binding<Range<Int>?> {
        Binding {
            selection?.captionID == caption.id ? selection?.range : nil
        } set: { range in
            selection = range.map { CaptionSelection(captionID: caption.id, range: $0) }
        }
    }

    private func lookUp(_ text: String) {
        jisho.search(text)
        panel.show(.jisho)
    }

    private func analyze(_ caption: Caption) {
        analyzer.analyze(caption)
        panel.show(.analysis)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch engine.status {
        case .failed(let message):
            ContentUnavailableView(
                "Can't caption", systemImage: "exclamationmark.triangle", description: Text(message)
            )
        case .listening, .reconnecting:
            ContentUnavailableView(
                "Waiting for a video", systemImage: "waveform",
                description: Text("The Chrome video's captions will come here.")
            )
        case .connecting(let message):
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(message)
            }
        case .idle:
            ContentUnavailableView(
                "LiveTrans", systemImage: "captions.bubble",
                description: Text("Press Start to caption and translate the Chrome video.")
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            let isDev = panel.isDev
            let canRerun = isDev && engine.isRunning && engine.serverCanPrefetch
            if canRerun || prefetch.playhead != nil {
                HStack(spacing: 10) {
                    if canRerun {
                        // Dev mode: Load and Stop below run the step; this
                        // makes it all again.
                        Button {
                            confirmRerun = true
                        } label: {
                            Label("Re-run", systemImage: "arrow.clockwise")
                                .frame(minWidth: 104)
                        }
                        .controlSize(.small)
                        .disabled(dev.job == nil)
                        .help("Forget what the host kept of this video and make it all again: the audio, step \(dev.step.title), speakers, words, captions and the other recognizers")
                        .confirmationDialog("Make this video's dev results again?", isPresented: $confirmRerun) {
                            Button("Re-run", role: .destructive) { dev.rerun() }
                        } message: {
                            Text("The host forgets what it kept of this video and fetches and makes it all again, which takes several minutes.")
                        }
                    }
                    if let playhead = prefetch.playhead {
                        VideoBar(
                            duration: dev.job?.duration ?? playhead.duration,
                            playhead: prefetch.position,
                            fetched: dev.fetched(on: playhead),
                            reached: dev.reached(on: playhead),
                            translated: dev.translated(on: playhead),
                            speakers: dev.speakerState(on: playhead),
                            isPaused: dev.isPaused,
                            onSeek: { prefetch.scrub(to: $0) }
                        )
                    } else {
                        Spacer()
                    }
                }
            }
            if let problem = dev.problem {
                // With the Mac's audio not heard, a video the host can't fetch
                // gets no captions: said here, not left to look like silence.
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if engine.isRunning && engine.listensToMac {
                LevelMeter(
                    level: engine.inputLevel,
                    threshold: engine.speechThreshold,
                    isSpeaking: engine.isSpeaking
                )
            }
            // The host starts and the step runs over the video; in Default,
            // Load for one it has processed, from what it kept of it.
            let loading = engine.isRunning && !dev.isPaused
            let processed = isDev && dev.isProcessed(dev.picked?.page ?? video.controlled?.url)
            HStack(spacing: 12) {
                TabPicker()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: isDev) {
                        if isDev { await dev.refreshProcessed() }
                    }
                Button {
                    if loading {
                        dev.hold()
                        // Incognito keeps the host, its job held in memory
                        // there, for Start to go on with; quitting ends it.
                        engine.stop(keepingHost: !isDev && dev.job != nil)
                    } else {
                        if !engine.isRunning { engine.start() }
                        dev.load()
                    }
                } label: {
                    Label(
                        loading ? "Stop" : processed ? "Load" : "Start",
                        systemImage: loading ? "stop.fill" : processed ? "tray.and.arrow.down.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: 240)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(loading ? .red : .green)
                .keyboardShortcut(.return, modifiers: .command)
                .help(loading ? "" : processed ? "Show this video's captions from what the host kept of it, making only what is missing" : "Fetch the Chrome video's audio and caption it")
                // As wide as the picker, which keeps the button in the middle.
                RunningStatus(items: dev.job?.running ?? [])
            }
        }
        .padding()
    }
}

/// Play/pause and 5-second skips for the video in Chrome.
private struct VideoControls: View {
    @Environment(ChromeVideo.self) private var video
    @Environment(DevPipeline.self) private var dev
    @Environment(Prefetcher.self) private var prefetch

    var body: some View {
        HStack(spacing: 12) {
            Button {
                video.send(.skip(seconds: -5))
            } label: {
                Image(systemName: "gobackward.5")
            }
            .help("Back 5 seconds in the Chrome video")
            Button {
                video.send(.toggle)
            } label: {
                Image(systemName: playSymbol)
                    .frame(width: 18)
            }
            .help("Play or pause the Chrome video (Space)")
            Button {
                video.send(.skip(seconds: 5))
            } label: {
                Image(systemName: "goforward.5")
            }
            .help("Forward 5 seconds in the Chrome video")
        }
        // Space plays from the pointer on the dev timeline once it has been
        // put somewhere, else plays or pauses.
        .background(SpaceKey { if !dev.playFromCursor(), video.send(.toggle) { prefetch.toggledByKey() } })
        // Keeps the picker's label on the tab the buttons would control,
        // which changes while LiveTrans is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            video.refreshTabsQuietly()
        }
        .alert(
            "Can't control the video",
            isPresented: Binding { video.problem != nil } set: { if !$0 { video.problem = nil } }
        ) {
            Button("OK") {}
        } message: {
            Text(video.problem ?? "")
        }
    }

    /// What clicking would do, as on a player's own button.
    private var playSymbol: String {
        switch video.state {
        case .playing: "pause.fill"
        case .paused: "play.fill"
        case .unknown: "playpause.fill"
        }
    }
}

/// Space plays and pauses, as in a video player, except where Space types:
/// an editable text view (the follow-up box, any field being edited) or a
/// text box on the Jisho page, such as its search box. Anywhere else on the
/// page, where Space would scroll, it is the video's. Each of those has the
/// cursor only after being clicked (`ClickFocusedWebView` keeps the page
/// from taking it as it loads), and Control-C takes the cursor back out of
/// the text, so that the next Space reaches the video without a click
/// somewhere else first.
struct SpaceKey: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    static func typesSpace(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView, text.isEditable { return true }
        guard let web = webView(around: responder) else { return false }
        // A page that doesn't say where its focus is might be typing.
        return (web as? ClickFocusedWebView)?.isEditingText ?? true
    }

    private static func webView(around responder: NSResponder?) -> WKWebView? {
        var view = responder as? NSView
        while let current = view {
            if let web = current as? WKWebView { return web }
            view = current.superview
        }
        return nil
    }

    /// What a key press in the window does; nil when it has been used up.
    static func handle(_ event: NSEvent, in window: NSWindow, toggle: () -> Void) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let typing = typesSpace(window.firstResponder)
        if event.keyCode == 49, modifiers.isEmpty, !typing {
            if !event.isARepeat { toggle() }
            return nil
        }
        if event.charactersIgnoringModifiers?.lowercased() == "c", modifiers == .control, typing {
            stopTyping(in: window)
            return nil
        }
        return event
    }

    /// Takes the cursor out of whatever is being typed in. A web page keeps
    /// its own idea of which box is focused, which would show a cursor still
    /// and take the focus straight back on the next click into the page.
    static func stopTyping(in window: NSWindow) {
        if let web = webView(around: window.firstResponder) {
            web.evaluateJavaScript("document.activeElement && document.activeElement.blur()")
        }
        window.makeFirstResponder(nil)
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return SpaceKey.handle(event, in: window, toggle: self.action)
            }
        }
    }
}

/// What the Mac plays sound on, changed here rather than in System Settings
/// when it is not what you are listening on. The router does the rest:
/// captioning on the Plugable goes through "BlackHole+Plugable".
private struct OutputPicker: View {
    @State private var output = SoundOutput()
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                Text(output.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.gray)
        }
        .help("Choose what the Mac plays sound on")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            OutputList(output: output) { isOpen = false }
        }
        .alert(
            "Can't switch the sound output",
            isPresented: Binding { output.problem != nil } set: { if !$0 { output.problem = nil } }
        ) {
            Button("OK") {}
        } message: {
            Text(output.problem ?? "")
        }
    }
}

struct OutputList: View {
    let output: SoundOutput
    let dismiss: () -> Void

    var body: some View {
        let snapshot = output.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.choices) { device in
                    let feed = snapshot.feed(for: device)
                    let unconnected = snapshot.needsConnecting(device)
                    row(
                        title: device.name,
                        detail: Self.detail(
                            feed: feed, captureName: snapshot.captureName, unconnected: unconnected
                        ),
                        symbol: unconnected ? "headphones" : feed == nil ? "speaker.slash" : "speaker.wave.2",
                        isChosen: snapshot.listening?.id == device.id || output.connecting?.id == device.id
                    ) {
                        output.choose(device)
                    }
                }
                if snapshot.choices.isEmpty {
                    Text("No sound output device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(6)
        }
        .frame(width: 340)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            output.refresh()
            output.refreshHeadphones()
        }
    }

    /// Whether captioning on the device would be heard by the captions.
    static func detail(feed: AudioHardware.Aggregate?, captureName: String, unconnected: Bool = false) -> String {
        let carried = feed.map { "captions via \($0.name)" }
            ?? "no Multi-Output Device pairs it with \(captureName)"
        return unconnected ? "connect · \(carried)" : carried
    }

    private func row(
        title: String, detail: String, symbol: String, isChosen: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(isChosen ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isChosen ? Color.orange.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Which Chrome tab the video buttons control: found automatically, or
/// chosen from all of Chrome's tabs.
private struct TabPicker: View {
    @Environment(ChromeVideo.self) private var video
    @Environment(DevPipeline.self) private var dev
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: video.pinned == nil && dev.picked == nil ? "sparkle.magnifyingglass" : "play.rectangle.fill")
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help("The video the app captions and controls: a Chrome tab, or one the host has processed. It stays on it until you choose another")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            TabList { isOpen = false }
        }
    }

    private var label: String {
        if let picked = dev.picked { return picked.label }
        if let pinned = video.pinned { return pinned.title.isEmpty ? pinned.url : pinned.title }
        return "Find the video"
    }
}

private struct TabList: View {
    @Environment(ChromeVideo.self) private var video
    @Environment(DevPipeline.self) private var dev
    @Environment(SidePanel.self) private var panel
    let dismiss: () -> Void

    var body: some View {
        // Only tabs with a video, and the chosen one even without.
        let shown = video.tabs.filter { $0.video != nil || $0.id == video.pinned?.id }
        let windows = Dictionary(grouping: shown, by: \.window)
        // A video open in a tab is that tab's row.
        let processed = panel.isDev ? dev.processed.filter { video in !shown.contains { $0.url == video.page } } : []
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(
                    title: "Find the video", detail: "The front tab of a Chrome window that has a video, kept from then on",
                    symbol: "sparkle.magnifyingglass", isChosen: video.pinned == nil && dev.picked == nil, isControlled: false
                ) {
                    dev.picked = nil
                    video.pin(nil)
                }
                ForEach(windows.keys.sorted(), id: \.self) { window in
                    Divider().padding(.vertical, 4)
                    Text("Window \(window)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    ForEach(windows[window] ?? []) { tab in
                        row(
                            title: tab.title.isEmpty ? tab.url : tab.title,
                            detail: Self.detail(tab, isControlled: video.controlled?.id == tab.id)
                                + (panel.isDev && dev.isProcessed(tab.url) ? " · processed" : ""),
                            symbol: video.controlled?.id == tab.id ? "play.rectangle.fill" : "play.rectangle",
                            isChosen: dev.picked == nil && video.pinned?.id == tab.id,
                            isControlled: video.controlled?.id == tab.id
                        ) {
                            dev.picked = nil
                            video.pin(tab)
                        }
                    }
                }
                if !processed.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Processed on the host")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    ForEach(processed) { video in
                        row(
                            title: video.label, detail: "Load opens it in Chrome",
                            symbol: "tray.and.arrow.down", isChosen: dev.picked?.id == video.id, isControlled: false
                        ) {
                            dev.picked = video
                        }
                    }
                }
                if video.isLoadingTabs {
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking tabs for videos…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                } else if shown.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("No Chrome tab has a video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(6)
        }
        .frame(width: 380)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: video.refreshTabs)
        .task {
            if panel.isDev { await dev.refreshProcessed() }
        }
    }

    private func row(
        title: String, detail: String, symbol: String, isChosen: Bool, isControlled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(isControlled || isChosen ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isControlled ? Color.orange.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func detail(_ tab: ChromeScript.Tab, isControlled: Bool) -> String {
        var parts = [URL(string: tab.url)?.host() ?? tab.url]
        switch tab.video {
        case .playing: parts.append("playing")
        case .paused: parts.append("paused")
        default: break
        }
        if isControlled { parts.append("controlled by the buttons") }
        return parts.joined(separator: " · ")
    }
}

private struct CaptionSelection: Equatable {
    let captionID: Int
    let range: Range<Int>
}

/// One other recognizer's text under a caption in dev mode: its name, then
/// the text with readings, as the caption's own. Also the text typed in
/// place of them all, under `Pick.typedName`.
private struct OtherHearingLine: View {
    let label: String
    let japanese: String
    let ruby: [RubyToken]
    let fontSize: Double
    let showFurigana: Bool
    var onClick: (() -> Void)?
    /// The row is hovered: the analysis button shows.
    var isRowHovered = false
    /// The side panel has this line's analysis.
    var isAnalyzed = false
    var onAnalyze: () -> Void = {}
    /// This line is the caption's, the others hidden.
    var isPicked = false
    /// A click on the name picks the line, or takes the pick back.
    var onPick: ((String?) -> Void)?
    /// Where the sentence is, shown on a line that stands for the caption.
    var span: String?
    /// The Chinese under the row is this line's.
    var isTranslated = false
    /// Shows this line's Chinese under the row; none when it has none.
    var onTranslate: (() -> Void)?
    /// Takes text typed from this line's as the caption.
    var onType: ((String) -> Void)?

    @State private var selection: Range<Int>?

    private var isTyped: Bool { label == Pick.typedName }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Self.name(label, fontSize: fontSize, showFurigana: showFurigana, isPicked: isPicked, onPick: onPick)
            FuriganaText(
                tokens: ruby, fontSize: fontSize, showReadings: showFurigana, selection: $selection, onClick: onClick
            )
            .help(isTyped ? "The caption as you typed it" : "What \(label) heard over the same stretch")
            if let onTranslate {
                Self.translateButton(
                    label, isTranslated: isTranslated, fontSize: fontSize, showFurigana: showFurigana, action: onTranslate
                )
            }
            if let onType {
                TypeButton(
                    text: japanese, fontSize: fontSize, showFurigana: showFurigana, isShown: isRowHovered, onSave: onType
                )
            }
            Spacer(minLength: 8)
            if let span {
                CaptionRow.spanLabel(span, fontSize: fontSize, showFurigana: showFurigana)
            }
            Button(action: onAnalyze) {
                Image(systemName: AnalysisView.symbol)
                    .font(.system(size: fontSize * 0.7))
                    .foregroundStyle(isAnalyzed ? Color.orange : Color.gray)
            }
            .buttonStyle(.plain)
            .help(isTyped ? "Explain the caption as you typed it" : "Explain what \(label) heard")
            // Level with its first line, below the row of readings.
            .padding(.top, showFurigana ? fontSize * 0.6 : 0)
            .opacity(isRowHovered || isAnalyzed ? 1 : 0)
        }
    }

    /// A small 中 after a recognizer's line that puts its Chinese under the
    /// row, green while it is the one there.
    static func translateButton(
        _ label: String, isTranslated: Bool, fontSize: Double, showFurigana: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text("中")
                .font(.system(size: fontSize * 0.5))
                .foregroundStyle(isTranslated ? Color.green : Color.gray)
                // A target a little wider than the glyph.
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isTranslated ? "The Chinese below is \(label)'s" : "Show \(label)'s Chinese below")
        .accessibilityLabel("\(label)'s Chinese")
        // On the baseline of its line, below the row of readings.
        .padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.4)
    }

    /// A recognizer's name at the left of its line, on the baseline of its
    /// first line, below the row of readings. With `onPick`, a button that
    /// picks the line, or takes the pick back when it is the one picked.
    @ViewBuilder
    static func name(
        _ label: String, fontSize: Double, showFurigana: Bool, isPicked: Bool = false, onPick: ((String?) -> Void)? = nil
    ) -> some View {
        let text = Text(label)
            .font(.system(size: fontSize * 0.5).monospaced())
            .foregroundStyle(isPicked ? Color.green : Color.gray)
            .frame(width: fontSize * 1.6, alignment: .leading)
        if let onPick {
            Button { onPick(isPicked ? nil : label) } label: { text.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(
                    label == Pick.typedName ? "Drop your text and show what was heard again"
                        : isPicked ? "Show all three again" : "Keep \(label)'s version and hide the others"
                )
                .padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.4)
        } else {
            text.padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.4)
        }
    }
}

/// A pencil after a line, shown with the row hovered, that opens an editor
/// with the line's text: for typing the caption when no recognizer heard
/// it right. Saved blank, the typed text is dropped.
private struct TypeButton: View {
    let text: String
    let fontSize: Double
    let showFurigana: Bool
    var isShown = true
    let onSave: (String) -> Void

    @State private var draft: String?

    var body: some View {
        Button { draft = text } label: {
            Image(systemName: Self.symbol)
                .font(.system(size: fontSize * 0.55))
                .foregroundStyle(Color.gray)
                // A target a little wider than the glyph.
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Type the caption yourself, starting from this text")
        .accessibilityLabel("Type the caption")
        // On the baseline of its line, below the row of readings.
        .padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.35)
        .opacity(isShown || draft != nil ? 1 : 0)
        .popover(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } }), arrowEdge: .bottom) {
            TypedCaptionEditor(text: draft ?? "") { typed in
                draft = nil
                if let typed { onSave(typed) }
            }
        }
    }

    static let symbol = "pencil"
}

/// The caption being typed, from the text of the line it was opened on:
/// Return or Save takes it, Escape or Cancel leaves the caption as it was.
struct TypedCaptionEditor: View {
    @State var text: String
    /// The text saved, or nil on Cancel.
    let onDone: (String?) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField("The caption as it was said", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .focused($isFocused)
                .onSubmit { onDone(text) }
                .frame(width: 380)
            HStack {
                Text("The host translates it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onDone(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { isFocused = true }
    }
}

struct CaptionRow: View {
    let caption: Caption
    let showFurigana: Bool
    let fontSize: Double
    /// The side panel has this caption's analysis.
    let isAnalyzed: Bool
    @Binding var selection: Range<Int>?
    let onAnalyze: () -> Void
    /// Plays the video from this sentence, on a click anywhere in the row.
    /// Nil when it wasn't heard from one.
    var onSeek: (() -> Void)?
    /// The sentence being spoken, among captions fetched ahead.
    var isCurrent = false
    /// The episode's official subtitle for the same moment, in dev mode.
    var official: String?
    /// What other recognizers heard over the same stretch, in dev mode,
    /// each under the caption's own Japanese with its name and readings.
    var others: [(label: String, sentence: Caption)] = []
    /// Whether the side panel has the analysis of one of `others`, and
    /// asking for it.
    var isOtherAnalyzed: (Caption) -> Bool = { _ in false }
    var onAnalyzeOther: (Caption) -> Void = { _ in }
    /// The recognizer picked, of "k2" and `others`: its line alone shows,
    /// with its translation. Nil, all of them with the caption's own.
    var picked: String?
    /// A click on a name picks it, or takes the pick back; none, and the
    /// names are only names.
    var onPick: ((String?) -> Void)?
    /// The text typed in place of every recognizer's, when there is one.
    var typed: Caption?
    /// Takes typed text as the caption, picked; none, and there is no
    /// pencil to type it with.
    var onType: ((String) -> Void)?

    @State private var isHovered = false
    /// The recognizer whose Chinese is under the lines, of `others`; nil,
    /// the caption's own, k2's.
    @State private var translatedBy: String?

    /// The other recognizer picked, when its text is among `others`.
    private var pickedOther: (label: String, sentence: Caption)? {
        others.first { $0.label == picked }
    }

    private var isOwnPicked: Bool { picked == "k2" && !others.isEmpty }

    /// The other recognizer whose Chinese shows: the one picked, else the
    /// one chosen by its 中, while it is still under the caption.
    private var translatingOther: (label: String, sentence: Caption)? {
        pickedOther ?? (isOwnPicked ? nil : others.first { $0.label == translatedBy })
    }

    /// With every line shown, each that has Chinese gets a 中 that puts it
    /// under them.
    private var isTranslationSwitchable: Bool { picked == nil && !others.isEmpty }

    /// The lines of the others under the caption's own, with no pick.
    private var othersShown: [(label: String, sentence: Caption)] {
        pickedOther.map { [$0] } ?? (isOwnPicked ? [] : others)
    }

    /// The typed text, when it is the caption: it alone shows.
    private var typedPicked: Caption? {
        picked == Pick.typedName ? typed : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let typed = typedPicked {
                    OtherHearingLine(
                        label: Pick.typedName, japanese: typed.japanese, ruby: typed.ruby, fontSize: fontSize,
                        showFurigana: showFurigana, onClick: onSeek, isRowHovered: isHovered,
                        isAnalyzed: isOtherAnalyzed(typed), onAnalyze: { onAnalyzeOther(typed) }, isPicked: true,
                        onPick: onPick, span: momentSpan, onType: onType
                    )
                } else {
                    if pickedOther == nil {
                        ownLine
                    }
                    ForEach(othersShown, id: \.label) { other in
                        OtherHearingLine(
                            label: other.label, japanese: other.sentence.japanese, ruby: other.sentence.ruby,
                            fontSize: fontSize, showFurigana: showFurigana, onClick: onSeek, isRowHovered: isHovered,
                            isAnalyzed: isOtherAnalyzed(other.sentence), onAnalyze: { onAnalyzeOther(other.sentence) },
                            isPicked: other.label == picked, onPick: onPick,
                            // Standing for the caption, it says where it is.
                            span: other.label == picked ? momentSpan : nil,
                            isTranslated: translatingOther?.label == other.label,
                            onTranslate: isTranslationSwitchable && !other.sentence.english.isEmpty
                                ? { translatedBy = other.label } : nil,
                            onType: onType
                        )
                    }
                }
                let english = typedPicked?.english ?? translatingOther?.sentence.english ?? caption.english
                if !english.isEmpty {
                    // Not SwiftUI's selectable text, which keeps its clicks.
                    SelectableText(english, size: fontSize * 0.82, color: .systemGreen, onClick: onSeek)
                } else if typedPicked != nil {
                    Text("No translation yet")
                        .font(.system(size: fontSize * 0.6))
                        .foregroundStyle(.gray)
                        .help("The host translates typed text when it has it; type it again if this stays")
                }
                if let official {
                    SelectableText(official, size: fontSize * 0.82, color: .systemOrange, onClick: onSeek)
                        .help("The episode's official subtitle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        // The highlight reaches a little past the text, without moving it.
        .padding(Self.highlightInset)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.green.opacity(0.3) : Color.white.opacity(isHovered && onSeek != nil ? 0.1 : 0))
                .strokeBorder(Color.green.opacity(isCurrent ? 0.9 : 0), lineWidth: 1.5)
                // Showing, a shape takes clicks; the row's must reach the
                // tracker behind it.
                .allowsHitTesting(false)
        )
        .background(HoverTracker(isHovered: $isHovered, onClick: onSeek))
        .padding(-Self.highlightInset)
    }

    /// The caption's own line, with its place and analysis.
    private var ownLine: some View {
        HStack(alignment: .top, spacing: 6) {
            // With the other recognizers under it, the caption's own
            // line is named too: ReazonSpeech k2's.
            if !others.isEmpty {
                OtherHearingLine.name(
                    "k2", fontSize: fontSize, showFurigana: showFurigana, isPicked: isOwnPicked, onPick: onPick
                )
                .help("What ReazonSpeech k2, the captions' own recognizer, heard")
            }
            FuriganaText(
                tokens: caption.ruby, fontSize: fontSize, showReadings: showFurigana,
                selection: $selection, onClick: onSeek
            )
            if isTranslationSwitchable, !caption.english.isEmpty {
                OtherHearingLine.translateButton(
                    "k2", isTranslated: translatingOther == nil, fontSize: fontSize, showFurigana: showFurigana
                ) { translatedBy = nil }
            }
            if let onType {
                TypeButton(
                    text: caption.japanese, fontSize: fontSize, showFurigana: showFurigana, isShown: isHovered,
                    onSave: onType
                )
            }
            Spacer(minLength: 8)
            if let momentSpan {
                Self.spanLabel(momentSpan, fontSize: fontSize, showFurigana: showFurigana)
            }
            Button(action: onAnalyze) {
                Image(systemName: AnalysisView.symbol)
                    .font(.system(size: fontSize * 0.7))
                    .foregroundStyle(isAnalyzed ? Color.orange : Color.gray)
            }
            .buttonStyle(.plain)
            .help("Explain this sentence")
            // Level with the Japanese, below the row of readings.
            .padding(.top, showFurigana ? fontSize * 0.6 : 0)
            .opacity(isHovered || isAnalyzed ? 1 : 0)
        }
    }

    private var momentSpan: String? {
        guard onSeek != nil, let moment = caption.moment else { return nil }
        return Self.span(of: moment)
    }

    /// Where a sentence is, at the right of its line.
    static func spanLabel(_ span: String, fontSize: Double, showFurigana: Bool) -> some View {
        Text(span)
            .font(.system(size: fontSize * 0.55).monospacedDigit())
            .foregroundStyle(.gray)
            // On the Japanese's baseline, below the row of readings.
            .padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.3)
            // Clicks go through it to the row.
            .allowsHitTesting(false)
    }

    static let highlightInset: CGFloat = 6

    /// "4:05–4:09", from where the sentence starts to where it ends; the
    /// start alone while the end is not known.
    static func span(of moment: VideoMoment) -> String {
        guard let end = moment.end else { return timestamp(moment.seconds) }
        return "\(timestamp(moment.seconds))–\(timestamp(end))"
    }

    /// "4:05", or "1:02:03" past the hour, as a player shows it.
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Whether the pointer is over a view, and clicks on the parts of it that
/// nothing else takes. SwiftUI's onHover only reports in the active app, and
/// the captions usually float over a video player that is.
struct HoverTracker: NSViewRepresentable {
    @Binding var isHovered: Bool
    /// A plain click, told after the double-click interval. Without one, a
    /// drag still moves the window.
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = { isHovered = $0 }
        view.isClickable = onClick != nil
        view.click.onClick = onClick ?? {}
    }

    final class TrackerView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var isClickable = false
        let click = SingleClick()

        override var mouseDownCanMoveWindow: Bool { !isClickable }

        // Captions float over another app, which is usually the active one:
        // the click must not be spent on activating the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isClickable }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            onChange(false)
        }

        override func mouseDown(with event: NSEvent) {
            guard isClickable else { return super.mouseDown(with: event) }
            click.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isClickable else { return super.mouseDragged(with: event) }
            click.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard isClickable else { return super.mouseUp(with: event) }
            click.mouseUp(with: event)
        }
    }
}

private struct StatusPill: View {
    let status: CaptionEngine.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch status {
        case .idle: .gray
        case .connecting: .yellow
        case .listening: .green
        case .reconnecting: .orange
        case .failed: .red
        }
    }

    private var label: String {
        switch status {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .listening(let server): server
        case .reconnecting: "GPU server down - reconnecting"
        case .failed: "Failed"
        }
    }
}

/// Input level against the VAD's current threshold. On a real microphone this
/// is the only way to see why speech is or isn't being picked up.
private struct LevelMeter: View {
    let level: Float
    let threshold: Float
    let isSpeaking: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(isSpeaking ? Color.green : Color.gray)
                    .frame(width: geometry.size.width * Self.position(level))
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * Self.position(threshold))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }

    /// int16 RMS on a dB scale, -70...-10 dBFS across the bar.
    private static func position(_ rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms / 32768)
        return CGFloat(min(max((decibels + 70) / 60, 0), 1))
    }
}

/// The header's pin: whether the window floats over the video or other
/// windows may cover it. The same setting as the switch in Settings.
struct KeepOnTopButton: View {
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false

    var body: some View {
        Button {
            keepOnTop.toggle()
        } label: {
            Image(systemName: keepOnTop ? "pin.fill" : "pin")
        }
        .accessibilityLabel("Keep window on top")
        .help(keepOnTop ? "On top of other windows; click to let them cover it" : "Keep this window on top of other windows")
    }
}

/// Window behaviour SwiftUI has no modifiers for.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    final class Coordinator {
        var placed = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The view has no window until after this update pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Floats above other apps, so captions stay visible over the video
            // they belong to.
            window.level = floating ? .floating : .normal
            // A floating window is treated as a palette and hidden during
            // Mission Control unless it says it is an ordinary managed window.
            window.collectionBehavior.insert(.managed)
            // The black content runs up under the title bar, which leaves no
            // visible place to grab; let any empty area drag the window.
            window.isMovableByWindowBackground = true

            if !context.coordinator.placed {
                context.coordinator.placed = true
                Self.moveToOpeningScreen(window)
            }
        }
    }

    /// Open where the user is looking. macOS restores the last position, or
    /// with none saved picks a display by rules of its own, and on a
    /// multi-display desk either can be a screen that is rarely looked at. A
    /// window already on the pointer's screen keeps its remembered position.
    /// Under development, GUI_SCREEN names the display to open on instead.
    private static func moveToOpeningScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let screen = GUIScreen.named ?? NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
              window.screen != screen
        else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: true)
    }
}

/// The Chrome video's timeline: where the viewer is, with a thumb to drag
/// the video elsewhere, and on it the stretches captioned ahead and the
/// audio fetched for the next.
struct VideoBar: View {
    let duration: Double?
    let playhead: Double?
    var captioned: [ClosedRange<Double>] = []
    var fetched: ClosedRange<Double>?
    /// In Default, how far each recognizer has captioned from the start,
    /// k2's first: each in its own color over the fetched audio.
    var reached: [(label: String, seconds: Double)] = []
    /// Under it, in lanes of their own: how far each one's text is
    /// translated, in the same colors, lighter; and where telling the
    /// speakers apart is.
    var translated: [(label: String, seconds: Double)] = []
    var speakers: DevPipeline.SpeakerState?
    var isPaused = false
    /// Called with where the thumb was dropped. The video only moves then:
    /// following the drag would play a moment of each place it passed, and
    /// the captions would hear them as sentences.
    var onSeek: ((Double) -> Void)?

    /// Where the thumb is being dragged, until it is dropped.
    @State private var dragged: Double?
    /// Where along the bar the pointer is, in points, while it is over it.
    @State private var pointer: CGFloat?

    static let thumb: CGFloat = 12
    static let barHeight: CGFloat = 16
    static let laneHeight: CGFloat = 3
    static let laneGap: CGFloat = 2
    /// How far above the bar the pointer's time floats, and its size,
    /// enough for "1:02:03" in the bar's font.
    static let labelRise: CGFloat = 12
    static let labelSize = CGSize(width: 50, height: 16)

    var body: some View {
        let total = max(duration ?? 0, fetched?.upperBound ?? 0, playhead ?? 0, 1)
        // A video with no end can't be moved about in.
        let canSeek = onSeek != nil && duration != nil
        let hasLanes = !translated.isEmpty || speakers != nil
        HStack(alignment: .top, spacing: 8) {
            Text(CaptionRow.timestamp(dragged ?? playhead ?? 0))
                .foregroundStyle(dragged == nil ? Color.gray : Color.orange)
                .frame(height: Self.barHeight)
            GeometryReader { geometry in
                let width = geometry.size.width
                VStack(alignment: .leading, spacing: Self.laneGap) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                            .frame(height: 6)
                        if let fetched {
                            stretch(fetched, of: total, in: width, color: Self.fetchedColor)
                        }
                        ForEach(Array(captioned.enumerated()), id: \.offset) { _, range in
                            stretch(range, of: total, in: width, color: (isPaused ? Color.yellow : Color.green).opacity(0.7))
                        }
                        // The one furthest behind drawn last, so each shows.
                        ForEach(Self.drawingOrder(reached), id: \.label) { reach in
                            if reach.seconds > 0 {
                                stretch(0...reach.seconds, of: total, in: width, color: Self.color(of: reach.label))
                            }
                        }
                        if let at = dragged ?? playhead {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: Self.thumb, height: Self.thumb)
                                .offset(x: width * Self.fraction(at, of: total) - Self.thumb / 2)
                        }
                    }
                    .frame(height: Self.barHeight)
                    if hasLanes {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                                .frame(height: Self.laneHeight)
                            ForEach(Self.drawingOrder(translated), id: \.label) { reach in
                                if reach.seconds > 0 {
                                    stretch(
                                        0...reach.seconds, of: total, in: width, color: Self.translatedColor(of: reach.label),
                                        height: Self.laneHeight
                                    )
                                }
                            }
                        }
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                                .frame(height: Self.laneHeight)
                            switch speakers {
                            case .done:
                                Capsule().fill(Self.speakersColor).frame(width: width, height: Self.laneHeight)
                            case .running:
                                // Striped: under way, over all of it at once.
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: Self.laneHeight / 2))
                                    path.addLine(to: CGPoint(x: width, y: Self.laneHeight / 2))
                                }
                                .stroke(Self.speakersColor, style: StrokeStyle(lineWidth: Self.laneHeight, dash: [4, 3]))
                                .frame(width: width, height: Self.laneHeight)
                            case .waiting, nil:
                                EmptyView()
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay {
                    BarDrag(
                        isEnabled: canSeek,
                        help: reached.isEmpty
                            ? Self.summary(
                                duration: duration, fetched: fetched?.upperBound, ready: captioned.map(\.upperBound).max()
                            )
                            : Self.summary(
                                duration: duration, fetched: fetched?.upperBound, reached: reached,
                                translated: translated, speakers: speakers
                            ),
                        onMove: { dragged = Self.seconds(at: $0, in: width, of: total) },
                        onDrop: {
                            onSeek?(Self.seconds(at: $0, in: width, of: total))
                            dragged = nil
                        },
                        onHover: { pointer = $0 }
                    )
                }
                .overlay(alignment: .topLeading) {
                    // The time under the pointer, floating above the bar, so
                    // a press lands where it was meant to. Drawn where the
                    // pointer is, kept from running off either end.
                    if canSeek, let pointer {
                        let half = Self.labelSize.width / 2
                        Text(CaptionRow.timestamp(Self.seconds(at: pointer, in: width, of: total)))
                            .foregroundStyle(.white)
                            .frame(width: Self.labelSize.width, height: Self.labelSize.height)
                            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .position(
                                x: min(max(pointer, half), max(width - half, half)),
                                y: -(Self.labelRise + Self.labelSize.height / 2)
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: Self.barHeight + (hasLanes ? 2 * (Self.laneGap + Self.laneHeight) : 0))
            Text(duration.map(CaptionRow.timestamp) ?? "live")
                .foregroundStyle(.gray)
                .frame(height: Self.barHeight)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement()
        .accessibilityLabel("Video position")
        .accessibilityValue(
            CaptionRow.timestamp(playhead ?? 0) + (duration.map { " of \(CaptionRow.timestamp($0))" } ?? "")
        )
    }

    private func stretch(
        _ range: ClosedRange<Double>, of total: Double, in width: CGFloat, color: Color, height: CGFloat = 6
    ) -> some View {
        let from = Self.fraction(range.lowerBound, of: total)
        return Capsule()
            .fill(color)
            .frame(width: width * (Self.fraction(range.upperBound, of: total) - from), height: height)
            .offset(x: width * from)
    }

    static func fraction(_ seconds: Double, of total: Double) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(max(seconds / total, 0), 1))
    }

    /// The place in the video under `x` of a bar `width` wide.
    static func seconds(at x: CGFloat, in width: CGFloat, of total: Double) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * total
    }

    /// Presses and drags along the bar, told as x within it, and the
    /// pointer's place over it, or nil once it has left. An AppKit view:
    /// the bar is used while Chrome is the active app, where a SwiftUI
    /// gesture would spend the press on activating the window, a drag
    /// that nothing takes moves the window, and SwiftUI's onHover only
    /// reports in the active app.
    struct BarDrag: NSViewRepresentable {
        var isEnabled: Bool
        var help: String
        var onMove: (CGFloat) -> Void
        var onDrop: (CGFloat) -> Void
        var onHover: (CGFloat?) -> Void = { _ in }

        func makeNSView(context: Context) -> DragView {
            DragView()
        }

        func updateNSView(_ view: DragView, context: Context) {
            view.isEnabled = isEnabled
            view.toolTip = help
            view.onMove = onMove
            view.onDrop = onDrop
            view.onHover = onHover
        }

        final class DragView: NSView {
            var isEnabled = false
            var onMove: (CGFloat) -> Void = { _ in }
            var onDrop: (CGFloat) -> Void = { _ in }
            var onHover: (CGFloat?) -> Void = { _ in }

            override var mouseDownCanMoveWindow: Bool { !isEnabled }

            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                trackingAreas.forEach(removeTrackingArea)
                addTrackingArea(NSTrackingArea(
                    rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self
                ))
            }

            override func mouseEntered(with event: NSEvent) {
                onHover(convert(event.locationInWindow, from: nil).x)
            }

            override func mouseMoved(with event: NSEvent) {
                onHover(convert(event.locationInWindow, from: nil).x)
            }

            override func mouseExited(with event: NSEvent) {
                onHover(nil)
            }

            override func mouseDown(with event: NSEvent) {
                guard isEnabled else { return super.mouseDown(with: event) }
                onMove(convert(event.locationInWindow, from: nil).x)
            }

            override func mouseDragged(with event: NSEvent) {
                guard isEnabled else { return super.mouseDragged(with: event) }
                let x = convert(event.locationInWindow, from: nil).x
                onMove(x)
                onHover(x)
            }

            override func mouseUp(with event: NSEvent) {
                guard isEnabled else { return super.mouseUp(with: event) }
                onDrop(convert(event.locationInWindow, from: nil).x)
            }
        }
    }

    /// What the bar says of captioning ahead, or how to use it when there
    /// is none.
    /// Each recognizer's color on the bar: none of them the playhead's
    /// orange, the paused yellow or Incognito's green.
    static func color(of recognizer: String) -> Color {
        switch recognizer {
        case "k2": Color.blue.opacity(0.85)
        case "nemo": Color.purple.opacity(0.9)
        default: Color.pink.opacity(0.9)
        }
    }

    /// A recognizer's translations, in the lane under the bar.
    static func translatedColor(of recognizer: String) -> Color {
        color(of: recognizer).opacity(0.5)
    }

    static let fetchedColor = Color.white.opacity(0.3)
    static let speakersColor = Color.green.opacity(0.7)

    /// Furthest first, so the one furthest behind is drawn over the others.
    static func drawingOrder(_ reached: [(label: String, seconds: Double)]) -> [(label: String, seconds: Double)] {
        reached.enumerated().sorted { a, b in
            a.element.seconds != b.element.seconds ? a.element.seconds > b.element.seconds : a.offset < b.offset
        }.map(\.element)
    }

    /// "k2 12:30 · nemo 8:10 · qwen 4:05, audio fetched to 18:05 of 24:05",
    /// and under it how far each is translated and the speakers' state.
    static func summary(
        duration: Double?, fetched: Double?, reached: [(label: String, seconds: Double)],
        translated: [(label: String, seconds: Double)] = [], speakers: DevPipeline.SpeakerState? = nil
    ) -> String {
        let whole = duration.map { " of \(CaptionRow.timestamp($0))" } ?? ""
        let times = { (reaches: [(label: String, seconds: Double)]) in
            reaches.map { "\($0.label) \(CaptionRow.timestamp($0.seconds))" }.joined(separator: " · ")
        }
        var lines = [times(reached) + ", audio fetched to \(CaptionRow.timestamp(fetched ?? 0))\(whole)"]
        if !translated.isEmpty { lines.append("Translated: " + times(translated)) }
        switch speakers {
        case .waiting: lines.append("Speakers: once the audio is all in")
        case .running: lines.append("Speakers: being told apart")
        case .done: lines.append("Speakers: told apart")
        case nil: break
        }
        return lines.joined(separator: "\n")
    }

    static func summary(duration: Double?, fetched: Double?, ready: Double?) -> String {
        guard fetched != nil || ready != nil else { return "Drag to move the Chrome video" }
        let whole = duration.map { " of \(CaptionRow.timestamp($0))" } ?? ""
        return "Captions ready to \(CaptionRow.timestamp(ready ?? 0)), "
            + "audio fetched to \(CaptionRow.timestamp(fetched ?? ready ?? 0))\(whole)"
    }
}
