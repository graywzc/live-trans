import SwiftUI

/// One sentence taken apart by the LLM: the sentence with its readings, the
/// Chinese translation, then a row per word. Rows appear as they arrive. Under
/// them, the questions asked about the sentence in the field at the bottom.
struct AnalysisView: View {
    static let symbol = "text.magnifyingglass"

    @Environment(SentenceAnalyzer.self) private var analyzer
    @Environment(JishoBrowser.self) private var jisho
    @Environment(SidePanel.self) private var panel
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
                        // The question goes to the top, with its answer
                        // growing into the room under it.
                        .onChange(of: analyzer.followUps.last?.id) { _, asked in
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
                    Text(analyzer.chinese)
                        .font(.system(size: fontSize * 0.82))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
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
                ForEach(analyzer.followUps) { followUp in
                    Divider()
                    FollowUpView(
                        followUp: followUp, fontSize: tableFontSize,
                        isLast: followUp.id == analyzer.followUps.last?.id
                    )
                    // Room for the newest question to reach the top of the
                    // panel before its answer has been written.
                    .frame(
                        minHeight: followUp.id == analyzer.followUps.last?.id ? viewportHeight - 45 : nil,
                        alignment: .top
                    )
                    .id(followUp.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // A word in the analyzed sentence can be looked up like one in a caption.
        .selectionActions { text in
            jisho.search(text)
            panel.show(.jisho)
        }
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
                            Text(word.reading)
                                .font(.system(size: tableFontSize * 0.7))
                                .foregroundStyle(.secondary)
                        }
                        Text(word.surface)
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(word.base)
                        Text(word.partOfSpeech)
                            .font(.system(size: tableFontSize * 0.75))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    Text(word.change.isEmpty ? "—" : word.change)
                        .foregroundStyle(word.change.isEmpty ? .secondary : .primary)
                    Text(word.meaning)
                }
            }
        }
        .font(.system(size: tableFontSize))
        .textSelection(.enabled)
    }
}

private struct FollowUpView: View {
    @Environment(SentenceAnalyzer.self) private var analyzer

    let followUp: FollowUp
    let fontSize: CGFloat
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(followUp.question)
                .foregroundStyle(.orange)
            if !followUp.answer.isEmpty {
                Text(Self.rendered(followUp.answer))
                    .lineSpacing(3)
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
        .textSelection(.enabled)
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
