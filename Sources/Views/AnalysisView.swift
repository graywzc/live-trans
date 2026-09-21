import SwiftUI

/// One sentence taken apart by the LLM: the sentence with its readings, the
/// Chinese translation, then a row per word. Rows appear as they arrive. Under
/// them, the questions asked about the sentence in the field at the bottom,
/// and an entry for each selection that was looked up. Any of the text can be
/// selected and looked up, an entry's own included.
struct AnalysisView: View {
    static let symbol = "text.magnifyingglass"

    @Environment(SentenceAnalyzer.self) private var analyzer
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0

    @State private var selection: Range<Int>?
    @FocusState private var questionIsFocused: Bool

    private var tableFontSize: CGFloat { max(fontSize * 0.7, 13) }

    var body: some View {
        switch analyzer.phase {
        case .idle:
            ContentUnavailableView(
                "Sentence analysis", systemImage: Self.symbol,
                description: Text("Point at a caption and click the button at its end to have the sentence explained.")
            )
        case .unconfigured:
            ContentUnavailableView {
                Label("No LLM server", systemImage: Self.symbol)
            } description: {
                Text("Enter the server and model to analyze sentences with under Sentence analysis in Settings.")
            } actions: {
                SettingsLink {
                    Text("Open Settings")
                }
                Button("Try Again", action: analyzer.retry)
            }
        case .running, .done, .failed:
            analysis
        }
    }

    private var analysis: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollViewReader { scroller in
                    thread(viewportHeight: viewport.size.height)
                        // The question or the looked-up text goes to the top,
                        // with what is written about it growing into the room
                        // under it.
                        .onChange(of: analyzer.thread.last?.id) { _, asked in
                            guard let asked else { return }
                            withAnimation { scroller.scrollTo(asked, anchor: .top) }
                        }
                }
            }
            Divider()
            questionField
        }
        .foregroundStyle(.white)
        // The selection is a range of the sentence that was showing.
        .onChange(of: analyzer.sentence) { selection = nil }
    }

    private func thread(viewportHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Readings always: they are the point here, whatever the
                // captions are set to.
                FuriganaText(tokens: analyzer.ruby, fontSize: fontSize, selection: $selection)
                if !analyzer.chinese.isEmpty {
                    SelectableText(analyzer.chinese, size: fontSize * 0.82, color: .systemOrange)
                }
                if !analyzer.words.isEmpty {
                    table
                }
                if case .failed(let message) = analyzer.phase {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Button("Try Again", action: analyzer.retry)
                    }
                    .font(.callout)
                }
                ForEach(analyzer.thread) { item in
                    Divider()
                    Group {
                        switch item {
                        case .followUp(let followUp):
                            FollowUpView(
                                followUp: followUp, fontSize: tableFontSize,
                                isLast: followUp.id == analyzer.followUps.last?.id
                            )
                        case .lookup(let lookup):
                            LookupView(
                                lookup: lookup, fontSize: tableFontSize,
                                isLoading: analyzer.lookingUp == lookup.id
                            ) {
                                analyzer.retryLookup(lookup.id)
                            }
                        }
                    }
                    // Room for the newest one to reach the top of the panel
                    // before anything has been written under it.
                    .frame(
                        minHeight: item.id == analyzer.thread.last?.id ? viewportHeight - 45 : nil,
                        alignment: .top
                    )
                    .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // The button a caption's selection gets, but the entry is the LLM's
        // and stays here: what is selected in an explanation is as often a
        // form or a term as a word, and jisho.org has the captions.
        .selectionActions(lookUpHelp: { "Look up \($0) with the LLM" }, onLookUp: analyzer.lookUp)
    }

    private var questionField: some View {
        @Bindable var analyzer = analyzer
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this sentence", text: $analyzer.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($questionIsFocused)
                .onSubmit(ask)
            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: tableFontSize * 1.3))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : .gray)
            .disabled(!canSend)
            .help("Ask (Return)")
        }
        .font(.system(size: tableFontSize))
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        analyzer.canAsk && !analyzer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The question stays in the field if it can't be asked yet.
    private func ask() {
        guard canSend else { return }
        analyzer.ask(analyzer.draft)
        analyzer.draft = ""
        questionIsFocused = true
    }

    private var table: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("词")
                Text("原形")
                Text("变化")
                // Takes the rest of the width, so the table spans the panel
                // from the first row on instead of growing as rows arrive.
                Text("句中意思")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: tableFontSize * 0.85, weight: .semibold))
            .foregroundStyle(.gray)
            ForEach(analyzer.words.filter { !$0.isPunctuation }) { word in
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        if word.reading != word.surface {
                            SelectableText(word.reading, size: tableFontSize * 0.7, color: .secondaryLabelColor)
                        }
                        SelectableText(word.surface, size: tableFontSize)
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        SelectableText(word.base, size: tableFontSize)
                        SelectableText(word.partOfSpeech, size: tableFontSize * 0.75, color: .secondaryLabelColor)
                    }
                    .fixedSize()
                    if word.change.isEmpty {
                        Text("—")
                            .foregroundStyle(.secondary)
                    } else {
                        SelectableText(word.change, size: tableFontSize)
                    }
                    SelectableText(word.meaning, size: tableFontSize)
                }
            }
        }
        .font(.system(size: tableFontSize))
    }
}

private struct FollowUpView: View {
    @Environment(SentenceAnalyzer.self) private var analyzer

    let followUp: FollowUp
    let fontSize: CGFloat
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SelectableText(followUp.question, size: fontSize, color: .systemOrange)
            if !followUp.answer.isEmpty {
                SelectableText(Self.rendered(followUp.answer), size: fontSize, lineSpacing: 3)
            } else if followUp.error == nil, isLast, analyzer.isAnswering {
                ProgressView()
                    .controlSize(.small)
            }
            if let error = followUp.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                if isLast {
                    Button("Try Again", action: analyzer.retryFollowUp)
                        .font(.callout)
                }
            }
        }
        .font(.system(size: fontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bold, italics and code as such; lists and line breaks as written. An
    /// answer that is still arriving, with its markup half open, reads as text.
    private static func rendered(_ answer: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        // Inline-only parsing leaves a list's markers as typed.
        let bulleted = answer.replacing(/(?m)^(\s*)[*-] +/) { "\($0.1)•  " }
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(answer)
    }
}
