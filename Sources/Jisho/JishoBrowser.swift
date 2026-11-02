import AppKit
import Observation
import WebKit

/// The web view behind the Jisho panel. It lives here rather than in the
/// panel's view so that a lookup can be started before the panel exists, and
/// so that closing the panel keeps the page and its history.
@MainActor
@Observable
final class JishoBrowser {
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false

    /// Made on first use: a web view costs a helper process, which a session
    /// that never looks anything up should not pay for.
    @ObservationIgnored private(set) lazy var webView = makeWebView()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func search(_ text: String) {
        guard let url = Jisho.searchURL(for: text) else { return }
        webView.load(URLRequest(url: url))
    }

    /// For the Jisho tab opened before anything was looked up.
    func loadHomeIfBlank() {
        guard webView.url == nil, !webView.isLoading, let url = URL(string: "https://jisho.org") else { return }
        webView.load(URLRequest(url: url))
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Lookups, cookies and cache stay in memory, gone with the app.
        configuration.websiteDataStore = .nonPersistent()
        let focus = TextFocusReporter()
        configuration.userContentController.addUserScript(TextFocusReporter.script)
        configuration.userContentController.add(focus, name: TextFocusReporter.name)
        let webView = ClickFocusedWebView(frame: .zero, configuration: configuration)
        focus.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.title = webView.title ?? "" }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
        ]
        return webView
    }
}

/// A web view that has the cursor only once it is clicked. Left to itself,
/// AppKit gives a new window's cursor to the first view that will take it,
/// and jisho.org's home page asks for it as it loads. Either way the panel,
/// in front from the first frame, would have Space typing into the search
/// box until something else was clicked, when it should play the video.
final class ClickFocusedWebView: WKWebView {
    /// The page's cursor is in a box that takes text, such as jisho.org's
    /// search box, rather than on the page itself, which Space would scroll.
    var isEditingText = false

    /// The event being handled is a click into this view.
    private var isBeingClicked: Bool {
        guard let event = NSApp.currentEvent, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return bounds.contains(convert(event.locationInWindow, from: nil))
        default:
            return false
        }
    }

    override var acceptsFirstResponder: Bool { isBeingClicked }

    /// WebKit hands the cursor to the page's focused box without asking
    /// `acceptsFirstResponder` first, so the answer is given here too.
    override func becomeFirstResponder() -> Bool {
        isBeingClicked && super.becomeFirstResponder()
    }
}

/// Tells the web view whether the page's focus is in a box that takes text.
/// The page keeps that to itself, and Space should type only there.
private final class TextFocusReporter: NSObject, WKScriptMessageHandler {
    static let name = "textFocus"
    static var script: WKUserScript { WKUserScript(source: """
        (() => {
          const kinds = /^(button|checkbox|radio|submit|reset|image|file|range|color)$/i;
          const editing = () => {
            const e = document.activeElement;
            if (!e) return false;
            if (e.isContentEditable || e.tagName === "TEXTAREA" || e.tagName === "SELECT") return true;
            return e.tagName === "INPUT" && !kinds.test(e.type);
          };
          const report = () => window.webkit.messageHandlers.\(name).postMessage(editing());
          document.addEventListener("focusin", report, true);
          // Focus has not moved on yet while focusout is handled.
          document.addEventListener("focusout", () => setTimeout(report, 0), true);
          report();
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true) }

    weak var webView: ClickFocusedWebView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let editing = message.body as? Bool ?? false
        MainActor.assumeIsolated { webView?.isEditingText = editing }
    }
}
