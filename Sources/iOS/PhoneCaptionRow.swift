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
                WordMenuItems(word: word, hasDefinition: WordMenuItems.dictionaryKnows(word)) { onWord($0, word) }
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
/// spoken. A tap plays the sentence again; the button at its end, when
/// there is one, asks for its analysis; a long press on a word, when
/// there is `onWord`, offers the word menu.
struct PhoneCaptionRow: View {
    let caption: Caption
    let fontSize: Double
    let showFurigana: Bool
    var isCurrent = false
    let onTap: () -> Void
    var onAnalyze: (() -> Void)? = nil
    var onWord: ((WordAction, String) -> Void)? = nil

    /// The highlight reaches a little past the text, without moving it.
    static let highlightInset: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                RubyText(tokens: caption.ruby, fontSize: fontSize, showReadings: showFurigana, onWord: onWord)
                if !caption.english.isEmpty {
                    Text(caption.english)
                        .font(.system(size: fontSize * 0.78))
                        .foregroundStyle(.green)
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
    }

    /// "4:05", a place in the video, with hours when there are any.
    static func timestamp(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        let pattern: Duration.TimeFormatStyle.Pattern = whole >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(whole).formatted(.time(pattern: pattern))
    }
}
