import SwiftUI

struct ContentView: View {
    @Environment(CaptionEngine.self) private var engine
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false

    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            captionList
            footer
        }
        .background(Color.black.ignoresSafeArea())
        .background(WindowLevel(floating: keepOnTop))
        .preferredColorScheme(.dark)
        .frame(minWidth: 420, minHeight: 300)
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
                        CaptionRow(caption: caption, showFurigana: showFurigana, fontSize: fontSize)
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

private struct CaptionRow: View {
    let caption: Caption
    let showFurigana: Bool
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showFurigana {
                FuriganaText(tokens: caption.ruby, fontSize: fontSize)
            } else {
                Text(caption.japanese)
                    .font(.system(size: fontSize))
            }
            if !caption.english.isEmpty {
                Text(caption.english)
                    .font(.system(size: fontSize * 0.82))
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(.white)
        .textSelection(.enabled)
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

/// Floats the window above other apps, so captions stay visible over the video
/// they belong to.
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The view has no window until after this update pass.
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}
