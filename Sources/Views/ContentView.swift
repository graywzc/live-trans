import SwiftUI

struct ContentView: View {
    @Environment(CaptionEngine.self) private var engine
    @Environment(JishoBrowser.self) private var jisho
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false
    @AppStorage(AppSettings.jishoPanelWidth) private var jishoWidth = 440.0

    /// One selection for the whole window, as in any text view.
    @State private var selection: CaptionSelection?

    private static let bottom = "bottom"
    private static let minCaptionsWidth: CGFloat = 420

    var body: some View {
        // A lookup opens Jisho beside the captions, not over them or in a
        // window that has to be found: the captions keep coming meanwhile.
        GeometryReader { proxy in
            let widest = max(proxy.size.width - Self.minCaptionsWidth - SplitHandle.width, JishoPanel.minWidth)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    captionList
                    footer
                }
                .frame(minWidth: Self.minCaptionsWidth, maxWidth: .infinity)
                if jisho.isPresented {
                    SplitHandle { x in
                        jishoWidth = min(max(proxy.size.width - x - SplitHandle.width / 2, JishoPanel.minWidth), widest)
                    }
                    JishoPanel()
                        .frame(width: min(max(jishoWidth, JishoPanel.minWidth), widest))
                }
            }
        }
        .frame(
            minWidth: Self.minCaptionsWidth + (jisho.isPresented ? SplitHandle.width + JishoPanel.minWidth : 0),
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
                            selection: selectionBinding(for: caption)
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

private struct CaptionSelection: Equatable {
    let captionID: Int
    let range: Range<Int>
}

private struct CaptionRow: View {
    let caption: Caption
    let showFurigana: Bool
    let fontSize: Double
    @Binding var selection: Range<Int>?

    var body: some View {
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
        .foregroundStyle(.white)
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
