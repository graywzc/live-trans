import Foundation

/// One row of the breakdown: a word as it stands in the sentence, and how it
/// got there from its dictionary form.
struct AnalyzedWord: Equatable, Identifiable {
    let id: Int
    var surface: String
    var reading: String
    var base: String
    var partOfSpeech: String
    var change: String
    var meaning: String

    /// Punctuation comes back as a row too, so that the rows still add up to
    /// the sentence, but there is nothing to say about it.
    var isPunctuation: Bool {
        base.isEmpty && meaning.isEmpty && partOfSpeech.isEmpty
    }
}

enum AnalysisEvent: Equatable {
    case translation(String)
    case word(AnalyzedWord)
}

/// What the LLM is asked for, and how its answer is read.
///
/// The answer is one JSON object per line rather than one document, so each
/// row can be shown as soon as its line is complete: the whole breakdown takes
/// ten seconds or more, the first line about two.
enum AnalysisFormat {
    static let instructions = """
        你是日语语法讲解助手。用户给出一句日语，请逐行输出 JSON（每行一个完整的 JSON 对象，\
        不要输出其他任何内容，不要使用 Markdown 代码块）。
        第一行：{"zh": "整句的自然简体中文翻译"}
        之后按句中出现的顺序，每个词一行：
        {"w": "句中原样的写法", "r": "该写法的平假名读音", "base": "原形（辞书形）", "pos": "词性", \
        "change": "从原形到句中形式的变化过程，没有变化则为空字符串", "meaning": "在本句中的意思"}
        要求：
        - 所有 w 依次拼接起来必须与原句完全一致（包括标点），不得增删改字。
        - 活用的动词、形容词连同其助动词作为一个词，例如「食べられなかった」是一行，\
        change 写「食べる → 可能形 食べられる → 否定 食べられない → 过去 食べられなかった」。
        - 助词单独成行；标点单独成行，其 r、base、pos、change、meaning 均为空字符串。
        - pos、change、meaning 用简体中文；专有名词保留原文。
        """

    /// Anything that is not one of the two kinds of line is dropped: a code
    /// fence, a stray remark, thinking that leaked into the answer.
    static func event(fromLine line: String, wordID: Int) -> AnalysisEvent? {
        struct Line: Decodable {
            var zh: String?
            var w: String?
            var r: String?
            var base: String?
            var pos: String?
            var change: String?
            var meaning: String?
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let parsed = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8))
        else { return nil }
        if let surface = parsed.w, !surface.isEmpty {
            return .word(AnalyzedWord(
                id: wordID, surface: surface, reading: parsed.r ?? "", base: parsed.base ?? "",
                partOfSpeech: parsed.pos ?? "", change: parsed.change ?? "", meaning: parsed.meaning ?? ""
            ))
        }
        if let chinese = parsed.zh, !chinese.isEmpty {
            return .translation(chinese)
        }
        return nil
    }
}

/// A streamed chat completion as it comes over HTTP.
enum ChatStream {
    /// The text in one line of the response: server-sent events,
    /// `data: {json}`. Reasoning comes in a field of its own and is not text.
    static func content(ofLine sseLine: String) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    var content: String?
                }
                var delta: Delta?
            }
            var choices: [Choice]?
        }
        guard sseLine.hasPrefix("data:") else { return nil }
        let payload = sseLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        else { return nil }
        return chunk.choices?.first?.delta?.content
    }
}

/// Turns the streamed answer, which arrives in arbitrary pieces, into events.
struct AnalysisStreamParser {
    private var pending = ""
    private var wordCount = 0

    mutating func consume(sseLine: String) -> [AnalysisEvent] {
        ChatStream.content(ofLine: sseLine).map { consume(content: $0) } ?? []
    }

    mutating func consume(content: String) -> [AnalysisEvent] {
        pending += content
        var events: [AnalysisEvent] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            append(line, to: &events)
        }
        return events
    }

    /// The last line usually ends without a newline.
    mutating func finish() -> [AnalysisEvent] {
        var events: [AnalysisEvent] = []
        append(pending, to: &events)
        pending = ""
        return events
    }

    private mutating func append(_ line: String, to events: inout [AnalysisEvent]) {
        guard let event = AnalysisFormat.event(fromLine: line, wordID: wordCount) else { return }
        if case .word = event { wordCount += 1 }
        events.append(event)
    }
}

extension Furigana {
    /// The sentence with the LLM's readings, which unlike the tokenizer's take
    /// the context into account (辛いラーメン as からい, not つらい). Nil unless the
    /// words really are the sentence, so a breakdown that dropped or rewrote
    /// something can't put readings over the wrong characters.
    static func annotate(_ sentence: String, words: [AnalyzedWord]) -> [RubyToken]? {
        guard !words.isEmpty, words.map(\.surface).joined() == sentence else { return nil }
        return words.flatMap { word -> [RubyToken] in
            if word.isPunctuation {
                return [RubyToken(base: word.surface, gluesToPrevious: true)]
            }
            let reading = word.reading.unicodeScalars.allSatisfy(isKana) ? word.reading : nil
            return annotate(word: word.surface, reading: reading.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }
}
