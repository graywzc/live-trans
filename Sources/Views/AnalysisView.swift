import SwiftUI

/// One sentence taken apart by the LLM: the sentence with its readings, the
/// Chinese translation, then a row per word. Rows appear as they arrive.
struct AnalysisView: View {
    static let symbol = "text.magnifyingglass"

    @Environment(SentenceAnalyzer.self) private var analyzer
    @Environment(JishoBrowser.self) private var jisho
    @Environment(SidePanel.self) private var panel
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0

    @State private var selection: Range<Int>?

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // A word in the analyzed sentence can be looked up like one in a caption.
        .selectionActions { text in
            jisho.search(text)
            panel.show(.jisho)
        }
        .foregroundStyle(.white)
        // The selection is a range of the sentence that was showing.
        .onChange(of: analyzer.sentence) { selection = nil }
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
