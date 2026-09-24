import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(CaptionEngine.self) private var engine
    @Environment(JishoBrowser.self) private var jisho
    @Environment(SentenceAnalyzer.self) private var analyzer
    @Environment(SidePanel.self) private var panel
    @Environment(ChromeVideo.self) private var video
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false
    @AppStorage(AppSettings.sidePanelWidth) private var panelWidth = 440.0

    /// One selection for the whole window, as in any text view.
    @State private var selection: CaptionSelection?

    private static let bottom = "bottom"
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

    private var header: some View {
        HStack(spacing: 16) {
            StatusPill(status: engine.status)
            Spacer()
            VideoControls()
            if !engine.captions.isEmpty {
                ShareLink(item: engine.transcript) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button(role: .destructive, action: engine.clear) {
                    Image(systemName: "trash")
                }
            }
            Text(AppVersion.display)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.gray.opacity(0.7))
                .help("LiveTrans version")
            SettingsLink {
                Image(systemName: "gearshape")
            }
        }
        .font(.body)
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var captionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(engine.captions) { caption in
                        CaptionRow(
                            caption: caption, showFurigana: showFurigana, fontSize: fontSize,
                            isAnalyzed: panel.isPresented && panel.tab == .analysis
                                && analyzer.hasAnalyzed(caption),
                            selection: selectionBinding(for: caption),
                            onAnalyze: { analyze(caption) },
                            onSeek: caption.moment.map { moment in { video.send(.seek(moment)) } }
                        )
                    }
                    if !engine.partialText.isEmpty {
                        Text(engine.partialText)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.gray)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .defaultScrollAnchor(.bottom)
            .selectionActions(onLookUp: lookUp)
            .overlay {
                if engine.captions.isEmpty, engine.partialText.isEmpty {
                    placeholder
                }
            }
            .onChange(of: engine.captions.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .onChange(of: engine.partialText) {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
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
                "Listening…", systemImage: "waveform",
                description: Text("Japanese speech will be captioned here.")
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
                description: Text("Press Start to caption and translate Japanese speech.")
            )
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if engine.isRunning {
                LevelMeter(
                    level: engine.inputLevel,
                    threshold: engine.speechThreshold,
                    isSpeaking: engine.isSpeaking
                )
            }
            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.start()
                }
            } label: {
                Label(
                    engine.isRunning ? "Stop" : "Start",
                    systemImage: engine.isRunning ? "stop.fill" : "mic.fill"
                )
                .font(.headline)
                .frame(maxWidth: 240)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(engine.isRunning ? .red : .green)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }
}

/// Play/pause and 5-second skips for the video in Chrome.
private struct VideoControls: View {
    @Environment(ChromeVideo.self) private var video

    var body: some View {
        HStack(spacing: 12) {
            TabPicker()
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
        .background(SpaceKey { video.send(.toggle) })
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
/// an editable text view (the follow-up box, any field being edited) or the
/// Jisho page, whose search box can't be told apart from the outside.
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
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
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
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 49,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                      !SpaceKey.typesSpace(window.firstResponder)
                else { return event }
                if !event.isARepeat { self.action() }
                return nil
            }
        }
    }
}

/// Which Chrome tab the video buttons control: found automatically, or
/// chosen from all of Chrome's tabs.
private struct TabPicker: View {
    @Environment(ChromeVideo.self) private var video
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: video.pinned == nil ? "sparkle.magnifyingglass" : "pin.fill")
                Text(label)
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
        .help("Choose which Chrome tab the video buttons control")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            TabList { isOpen = false }
        }
    }

    private var label: String {
        if let pinned = video.pinned { return pinned.title }
        if let linked = video.linked { return "Auto: \(linked.title)" }
        return "Auto"
    }
}

private struct TabList: View {
    @Environment(ChromeVideo.self) private var video
    let dismiss: () -> Void

    var body: some View {
        // Only tabs with a video, and the chosen one even without.
        let shown = video.tabs.filter { $0.video != nil || $0.id == video.pinned?.id }
        let windows = Dictionary(grouping: shown, by: \.window)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row(
                    title: "Automatic", detail: "The front tab of a Chrome window that has a video",
                    symbol: "sparkle.magnifyingglass", isChosen: video.pinned == nil, isControlled: false
                ) {
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
                            detail: Self.detail(tab, isControlled: video.controlled?.id == tab.id),
                            symbol: video.controlled?.id == tab.id ? "play.rectangle.fill" : "play.rectangle",
                            isChosen: video.pinned?.id == tab.id,
                            isControlled: video.controlled?.id == tab.id
                        ) {
                            video.pin(tab)
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

struct CaptionRow: View {
    let caption: Caption
    let showFurigana: Bool
    let fontSize: Double
    /// The side panel has this caption's analysis.
    let isAnalyzed: Bool
    @Binding var selection: Range<Int>?
    let onAnalyze: () -> Void
    /// Plays the video from this sentence. Nil when it wasn't heard from one.
    var onSeek: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FuriganaText(
                    tokens: caption.ruby, fontSize: fontSize, showReadings: showFurigana,
                    selection: $selection
                )
                if !caption.english.isEmpty {
                    Text(caption.english)
                        .font(.system(size: fontSize * 0.82))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onSeek, let moment = caption.moment {
                Button(action: onSeek) {
                    Text(Self.timestamp(moment.seconds))
                        .font(.system(size: fontSize * 0.55).monospacedDigit())
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Play the video from this sentence")
                // On the Japanese's baseline, below the row of readings.
                .padding(.top, (showFurigana ? fontSize * 0.6 : 0) + fontSize * 0.3)
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
        .foregroundStyle(.white)
        .background(HoverTracker(isHovered: $isHovered))
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

/// Whether the pointer is over a view. SwiftUI's onHover only reports in the
/// active app, and the captions usually float over a video player that is.
struct HoverTracker: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> TrackerView {
        TrackerView()
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = { isHovered = $0 }
    }

    final class TrackerView: NSView {
        var onChange: (Bool) -> Void = { _ in }

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

/// Window behaviour SwiftUI has no modifiers for.
private struct WindowLevel: NSViewRepresentable {
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
                Self.moveToPointerScreen(window)
            }
        }
    }

    /// Open where the user is looking. macOS restores the last position, or
    /// with none saved picks a display by rules of its own, and on a
    /// multi-display desk either can be a screen that is rarely looked at. A
    /// window already on the pointer's screen keeps its remembered position.
    private static func moveToPointerScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
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
