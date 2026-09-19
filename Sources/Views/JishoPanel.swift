import SwiftUI
import WebKit

/// jisho.org in the right-hand part of the window, so a lookup doesn't mean
/// leaving for a browser and finding the way back to the captions.
struct JishoPanel: View {
    static let minWidth: CGFloat = 320

    @Environment(JishoBrowser.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack(spacing: 16) {
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
                Text(browser.title.isEmpty ? "Jisho" : browser.title)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                Spacer()
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
                Button {
                    browser.isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close Jisho")
                .keyboardShortcut(.cancelAction)
            }
            .font(.body)
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 10)
            WebView(webView: browser.webView)
        }
    }
}

/// The divider between the captions and Jisho; drag it to resize. SwiftUI's
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
