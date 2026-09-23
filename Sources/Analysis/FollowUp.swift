import Foundation

/// A question asked about the analyzed sentence, and the answer so far.
struct FollowUp: Equatable, Identifiable {
    let id: Int
    let question: String
    /// The answer's text as the server wrote it.
    var raw = ""
    var error: String?

    var answer: String {
        FollowUpFormat.visible(raw)
    }
}

/// What the LLM is told for a follow-up question. The analysis on screen is
/// the context; it travels in the request, since the server has kept nothing
/// of it.
enum FollowUpFormat {
    static let instructions = """
        你是日语讲解助手。下面是一句日语，以及已经给用户看过的翻译和逐词分析。\
        用户会就这句话里的词汇、语法、用法等继续提问。
        要求：
        - 用简体中文回答，日语的词句保留原文，必要时在括号里注上平假名读音。
        - 简明扼要，直接回答所问；需要举例时例句要短，并附中文翻译。
        - 可以使用粗体和列表，不要使用标题、表格和代码块。
        """

    /// The question the Grammar button asks about a selection.
    static func grammarQuestion(about text: String) -> String {
        "「\(text)」在这句话里是什么语法？请说明它的接续、含义和用法。"
    }

    /// The system message: the instructions, then what the panel is showing.
    static func context(sentence: String, chinese: String, words: [AnalyzedWord]) -> String {
        var lines = [instructions, "", "句子：\(sentence)"]
        if !chinese.isEmpty {
            lines.append("翻译：\(chinese)")
        }
        let rows = words.filter { !$0.isPunctuation }
        if !rows.isEmpty {
            lines.append("逐词分析（词｜读音｜原形｜词性｜变化｜句中意思）：")
            lines += rows.map { word in
                [word.surface, word.reading, word.base, word.partOfSpeech, word.change.isEmpty ? "—" : word.change,
                 word.meaning].joined(separator: "｜")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The conversation about this sentence so far, then the new question. An
    /// earlier question that got no answer is left out: there is nothing for
    /// the new one to refer back to, and two user turns in a row is an error
    /// to some chat templates.
    static func messages(
        asking question: String, after earlier: [FollowUp],
        sentence: String, chinese: String, words: [AnalyzedWord]
    ) -> [[String: String]] {
        var messages = [["role": "system", "content": context(sentence: sentence, chinese: chinese, words: words)]]
        for followUp in earlier where !followUp.answer.isEmpty {
            messages.append(["role": "user", "content": followUp.question])
            messages.append(["role": "assistant", "content": followUp.answer])
        }
        messages.append(["role": "user", "content": question])
        return messages
    }

    /// Without the thinking of a model that thinks anyway and whose server
    /// leaves it in the content: nothing until the thinking is over.
    static func visible(_ raw: String) -> String {
        var text = Substring(raw)
        let leading = text.drop(while: \.isWhitespace)
        if leading.hasPrefix("<think>") {
            guard let end = leading.range(of: "</think>") else { return "" }
            text = leading[end.upperBound...]
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
