import SwiftUI
import WebKit

/// What the right-hand part of the window is showing. Jisho and the sentence
/// analysis share it: one place to look, one divider, one width.
@MainActor
@Observable
final class SidePanel {
    enum Tab: Hashable {
        case jisho
        case analysis
    }

    var isPresented = false
    var tab = Tab.jisho

    func show(_ tab: Tab) {
        self.tab = tab
        isPresented = true
    }

    /// The panel can be open from the first frame when the app is launched
    /// with `-sidePanel jisho` or `-sidePanel analysis` (UserDefaults reads
    /// such arguments), so a run of the app can show both halves of the
    /// window without a caption to look up first. Nothing is persisted: the
    /// next ordinary launch starts with the captions alone again.
    func openIfRequestedAtLaunch(defaults: UserDefaults = .standard) {
        switch defaults.string(forKey: "sidePanel") {
        case "jisho": show(.jisho)
        case "analysis": show(.analysis)
        default: break
        }
    }
}

/// Beside the captions rather than over them or in a window that has to be
/// found, so a lookup doesn't mean losing the captions. Each tab keeps what it
/// was showing while the other one is in front, and while the panel is closed.
struct SidePanelView: View {
    static let minWidth: CGFloat = 320

    @Environment(SidePanel.self) private var panel
    @Environment(JishoBrowser.self) private var browser
    @Environment(SentenceAnalyzer.self) private var analyzer

    var body: some View {
        @Bindable var panel = panel
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Panel", selection: $panel.tab) {
                    Text("Jisho").tag(SidePanel.Tab.jisho)
                    Text("Analysis").tag(SidePanel.Tab.analysis)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                switch panel.tab {
                case .jisho: jishoControls
                case .analysis: analysisControls
                }
                Button {
                    panel.isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close the panel")
                .keyboardShortcut(.cancelAction)
            }
            .font(.body)
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 10)
            switch panel.tab {
            case .jisho:
                WebView(webView: browser.webView)
                    .onAppear(perform: browser.loadHomeIfBlank)
            case .analysis: AnalysisView()
            }
        }
    }

    @ViewBuilder
    private var jishoControls: some View {
        Button {
            browser.webView.goBack()
        } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(!browser.canGoBack)
        .help("Back")
        Button {
            browser.webView.goForward()
        } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(!browser.canGoForward)
        .help("Forward")
        Text(browser.title)
            .font(.caption)
            .foregroundStyle(.gray)
            .lineLimit(1)
        Spacer(minLength: 0)
        if browser.isLoading {
            ProgressView()
                .controlSize(.small)
        }
        Button {
            if let url = browser.webView.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Image(systemName: "safari")
        }
        .help("Open this page in your browser")
    }

    @ViewBuilder
    private var analysisControls: some View {
        Spacer(minLength: 0)
        if analyzer.isBusy {
            ProgressView()
                .controlSize(.small)
            Button(action: analyzer.cancel) {
                Image(systemName: "stop.fill")
            }
            .help(
                analyzer.analyzing != nil ? "Stop the analysis"
                    : analyzer.isAnswering ? "Stop the answer" : "Stop the lookup"
            )
        }
        Button(action: analyzer.clear) {
            Image(systemName: "trash")
        }
        .disabled(analyzer.analyses.isEmpty)
        .help("Clear the analyses, and start the questions over")
    }
}

/// The divider between the captions and the panel; drag it to resize. SwiftUI's
/// HSplitView would do the dragging but opens a pane at its minimum width
/// every time, and its divider position can be neither set nor saved.
struct SplitHandle: NSViewRepresentable {
    static let width: CGFloat = 7

    /// The pointer's x in the window while dragging.
    let onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HandleView, context: Context) -> CGSize? {
        CGSize(width: Self.width, height: proposal.height ?? 0)
    }

    final class HandleView: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }

        // The window is movable by its background; this drag is not that.
        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            onDrag(event.locationInWindow.x)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

private struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
