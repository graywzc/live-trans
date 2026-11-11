import SwiftUI

/// Japanese with readings printed above the kanji: each word a small
/// two-row stack, wrapped like text by the shared FlowLayout, as
/// FuriganaText lays it out on the Mac. In place of the Mac's selection,
/// a long press on a piece lifts out the whole word it belongs to (see
/// RubyWords) with the word menu, when the text has `onWord`.
struct RubyText: View {
    let tokens: [RubyToken]
    let fontSize: Double
    var showReadings = true
    /// What the menu's items do with the word pressed; none, and a press
    /// does nothing.
    var onWord: ((WordAction, String) -> Void)? = nil

    var body: some View {
        FlowLayout(lineSpacing: fontSize * 0.15) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                piece(token, at: index)
                    .layoutValue(key: GluesToPrevious.self, value: token.gluesToPrevious)
            }
        }
    }

    @ViewBuilder
    private func piece(_ token: RubyToken, at index: Int) -> some View {
        let stack = VStack(spacing: 0) {
            if showReadings {
                // A blank reading still takes its row, so every word has
                // the same height and the base text shares one baseline.
                Text(token.reading ?? " ")
                    .font(.system(size: fontSize * 0.5))
                    .foregroundStyle(.secondary)
            }
            Text(token.base)
                .font(.system(size: fontSize))
        }
        .fixedSize()
        if let onWord {
            let range = RubyWords.word(at: index, in: tokens)
            let word = RubyWords.text(of: range, in: tokens)
            stack.contextMenu {
                WordMenuItems(word: word) { onWord($0, word) }
            } preview: {
                WordPreview(tokens: Array(tokens[range]), fontSize: fontSize)
            }
        } else {
            stack
        }
    }
}

/// One caption: the Japanese with its readings, the translation under
/// it, where in the video it was said at its end, lit while it is being
/// spoken. Heard by several recognizers, each one's text is stacked with
/// its name, a tap on which picks it: the others hide and the translation
/// is the picked text's, and a tap on the name again brings them back,
/// on this row only until another is picked (`VersionsShown`).
/// With `onType`, a pencil after each line opens an editor with its text,
/// for typing the caption when none heard it right: saved, it is picked
/// under `Pick.typedName`. A tap elsewhere plays the sentence again; the
/// button at its end, when there is one, asks for its analysis; a long
/// press on a word, when there is `onWord`, offers the word menu.
struct PhoneCaptionRow: View, Equatable {
    let caption: Caption
    let fontSize: Double
    let showFurigana: Bool
    var isCurrent = false
    /// The recognizer picked, of the caption's versions, or
    /// `Pick.typedName` for `typed`.
    var picked: String? = nil
    /// The text typed in place of every recognizer's, when there is one.
    var typed: Caption? = nil
    let onTap: () -> Void
    var onPick: ((String?) -> Void)? = nil
    /// Takes typed text as the caption; blank, drops it.
    var onType: ((String) -> Void)? = nil
    var onAnalyze: (() -> Void)? = nil
    var onWord: ((WordAction, String, Caption) -> Void)? = nil

    /// The text in the editor, while it is open.
    @State private var draft: String?
    @State private var versionsShown = VersionsShown()

    /// The one shown alone, of `picked`; nil while all of them show.
    private var shownPick: String? { versionsShown.shown(picked) }

    /// What can change what the row draws: a caption never changes, nor
    /// does what the closures do with it. With `.equatable()` in the list
    /// the lit caption moving on redraws its two rows, not the screenful.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.caption.id == b.caption.id && a.fontSize == b.fontSize && a.showFurigana == b.showFurigana
            && a.isCurrent == b.isCurrent && a.picked == b.picked && a.typed == b.typed
    }

    /// The highlight reaches a little past the text, without moving it.
    static let highlightInset: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                let typedPicked = shownPick == Pick.typedName ? typed : nil
                let shown = typedPicked ?? caption.heard(by: shownPick)
                if let typedPicked {
                    labelled(Pick.typedName, typedPicked, isPicked: true)
                } else if caption.versions.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        ruby(of: shown)
                        typeButton(from: shown.japanese)
                    }
                } else if let version = caption.versions.first(where: { $0.name == shownPick }) {
                    labelled(version)
                } else {
                    ForEach(caption.versions, id: \.name) { labelled($0) }
                }
                if !shown.english.isEmpty {
                    Text(shown.english)
                        .font(.system(size: fontSize * 0.78))
                        .foregroundStyle(.green)
                } else if typedPicked != nil {
                    Text("No translation yet")
                        .font(.system(size: fontSize * 0.6))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if let moment = caption.moment {
                    Text(Self.timestamp(moment.seconds))
                        .font(.system(size: fontSize * 0.55).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let onAnalyze {
                    Button(action: onAnalyze) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: fontSize * 0.8))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Explain this sentence")
                }
            }
            // Level with the Japanese, below the row of readings.
            .padding(.top, showFurigana ? fontSize * 0.6 : 0)
        }
        .padding(Self.highlightInset)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.green.opacity(0.25) : Color.clear)
                .strokeBorder(Color.green.opacity(isCurrent ? 0.9 : 0), lineWidth: 1.5)
        )
        .padding(-Self.highlightInset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays this sentence again")
        .alert("The caption", isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            TextField("As it was said", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let draft, let onType {
                    versionsShown.typed()
                    onType(draft)
                }
            }
        } message: {
            Text("Typed in place of what was heard; the host translates it.")
        }
    }

    /// A pencil chip after a line that opens the editor with `text`.
    @ViewBuilder
    private func typeButton(from text: String) -> some View {
        if onType != nil {
            Button {
                draft = text
            } label: {
                Image(systemName: Self.typeSymbol)
                    .font(.system(size: fontSize * 0.55, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Type the caption")
            // Level with the Japanese, below the row of readings.
            .padding(.top, showFurigana ? fontSize * 0.45 : 0)
        }
    }

    static let typeSymbol = "pencil"

    private func ruby(of caption: Caption) -> some View {
        RubyText(
            tokens: caption.ruby, fontSize: fontSize, showReadings: showFurigana,
            onWord: onWord.map { act in { action, word in act(action, word, caption) } }
        )
    }

    /// A version's text after its name.
    private func labelled(_ version: CaptionVersion) -> some View {
        labelled(version.name, caption.heard(by: version.name), isPicked: version.name == shownPick)
    }

    /// `shown`'s text after `name`, and the pencil after it.
    private func labelled(_ name: String, _ shown: Caption, isPicked: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                if let onPick { versionsShown.click(isPicked ? nil : name, picked: picked, pick: onPick) }
            } label: {
                Text(name)
                    .font(.system(size: fontSize * 0.6, weight: .medium))
                    .foregroundStyle(isPicked ? Color.green : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isPicked ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                name == Pick.typedName ? "Drop your text and show all versions"
                    : isPicked ? "Show what each recognizer heard" : "Keep \(name)'s version"
            )
            // Level with the Japanese, below the row of readings.
            .padding(.top, showFurigana ? fontSize * 0.45 : 0)
            ruby(of: shown)
            typeButton(from: shown.japanese)
        }
    }

    /// "4:05", a place in the video, with hours when there are any.
    static func timestamp(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        let pattern: Duration.TimeFormatStyle.Pattern = whole >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(whole).formatted(.time(pattern: pattern))
    }
}
