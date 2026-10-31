import SwiftUI
import UIKit
import WebKit

/// What a long press on a word of a caption offers, on the phone, in
/// place of the Mac's selection and its floating buttons: the web
/// dictionary, Apple's own, the LLM's entry with its grammar, and the
/// clipboard. Copy is done here; the others open a sheet, which is the
/// screen's to do.
enum WordAction: Equatable {
    case jisho
    case dictionary
    case grammar
}

/// The menu's items. Apple's dictionaries are downloaded by the user in
/// Settings, so a word may have no definition yet: then that item is
/// greyed out, the way the Mac greys Grammar while it cannot be asked.
struct WordMenuItems: View {
    let word: String
    let hasDefinition: Bool
    let onAction: (WordAction) -> Void

    var body: some View {
        Button("Jisho", systemImage: "character.book.closed") { onAction(.jisho) }
        Button("Dictionary", systemImage: "book.closed") { onAction(.dictionary) }
            .disabled(!hasDefinition)
        Button("Grammar", systemImage: "text.book.closed") { onAction(.grammar) }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = word }
    }

    /// Whether Apple's dictionaries know the term.
    @MainActor
    static func dictionaryKnows(_ word: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word)
    }
}

/// The word lifted out of its row while the menu is up: every piece of
/// it, readings and all, so a word split for its readings shows whole.
struct WordPreview: View {
    let tokens: [RubyToken]
    let fontSize: Double

    var body: some View {
        RubyText(tokens: tokens, fontSize: fontSize * 1.4)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemBackground))
    }
}

/// jisho.org's entry for the word, in a web view of its own. Its cookies
/// and cache stay in memory and go with the sheet, as the Mac's do.
struct JishoSheet: View {
    let word: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            JishoWebView(url: Jisho.searchURL(for: word))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(word)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct JishoWebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Apple's dictionaries on the word: offline, once the user has added a
/// Japanese one under Settings › General › Dictionary.
struct DictionarySheet: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
