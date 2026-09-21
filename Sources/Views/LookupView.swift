import SwiftUI

/// A looked-up selection, set out the way jisho.org sets out a word: the
/// headword under its reading, tags, numbered meanings under their part of
/// speech, then the grammar. All of it can be selected and looked up in turn.
struct LookupView: View {
    static let symbol = "character.book.closed"

    let lookup: Lookup
    let fontSize: CGFloat
    /// The entry is still being written.
    let isLoading: Bool
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol)
                SelectableText(lookup.text, size: fontSize * 0.85, weight: .semibold, color: .systemGray)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.system(size: fontSize * 0.85))
            .foregroundStyle(.gray)
            ForEach(lookup.entries) { entry in
                EntryView(entry: entry, fontSize: fontSize)
            }
            if !lookup.grammar.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("语法")
                        .font(.system(size: fontSize * 0.85, weight: .semibold))
                        .foregroundStyle(.gray)
                    ForEach(lookup.grammar) { point in
                        VStack(alignment: .leading, spacing: 2) {
                            SelectableText(point.form, size: fontSize, weight: .semibold)
                            if !point.explanation.isEmpty {
                                SelectableText(point.explanation, size: fontSize, color: .lightGray)
                            }
                        }
                    }
                }
            }
            if let error = lookup.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                if let onRetry {
                    Button("Try Again", action: onRetry)
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EntryView: View {
    let entry: DictionaryEntry
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if !entry.reading.isEmpty, entry.reading != entry.headword {
                    SelectableText(entry.reading, size: fontSize * 0.8, color: .lightGray)
                }
                SelectableText(entry.headword, size: fontSize * 1.7)
            }
            if !entry.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: fontSize * 0.7, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.color(ofTag: tag), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            ForEach(Array(entry.senses.enumerated()), id: \.element.id) { index, sense in
                // As on jisho.org, the part of speech heads the meanings
                // that share it rather than being repeated on each.
                if !sense.partOfSpeech.isEmpty,
                   index == 0 || entry.senses[index - 1].partOfSpeech != sense.partOfSpeech {
                    SelectableText(sense.partOfSpeech, size: fontSize * 0.8, color: .systemGray)
                        .padding(.top, 2)
                }
                SenseView(sense: sense, number: index + 1, fontSize: fontSize)
            }
        }
    }

    /// jisho.org's green for a common word; grey for the rest.
    private static func color(ofTag tag: String) -> Color {
        tag.contains("常用") ? Color(red: 0.35, green: 0.6, blue: 0.2) : Color(white: 0.35)
    }
}

private struct SenseView: View {
    let sense: Sense
    let number: Int
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.system(size: fontSize).monospacedDigit())
                .foregroundStyle(.gray)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    SelectableText(sense.definition, size: fontSize)
                    if sense.appliesHere {
                        Text("本句")
                            .font(.system(size: fontSize * 0.7, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 3))
                            .help("The meaning in this sentence")
                    }
                }
                if !sense.note.isEmpty {
                    SelectableText(sense.note, size: fontSize * 0.85, color: .lightGray)
                }
                if !sense.example.isEmpty {
                    SelectableText(sense.example, size: fontSize * 0.9, color: .lightGray)
                        .padding(.top, 2)
                    if !sense.exampleChinese.isEmpty {
                        SelectableText(sense.exampleChinese, size: fontSize * 0.85, color: .systemGray)
                    }
                }
            }
        }
    }
}
