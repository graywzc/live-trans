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

/// What the LLM is told for a follow-up question. Every sentence analyzed so
/// far is the context, with the questions asked in between, in the order they
/// came; it travels in the request, since the server has kept nothing of it.
enum FollowUpFormat {
    static let instructions = """
        你是日语讲解助手。用户在看日语视频时，先后请你分析了若干句日语，每句的翻译和逐词分析都已经给用户看过；\
        用户会就这些句子里的词汇、语法、用法等继续提问。问题通常是关于最近分析的那一句，但也可能涉及前面的句子。
        要求：
        - 用简体中文回答，日语的词句保留原文，必要时在括号里注上平假名读音。
        - 简明扼要，直接回答所问；需要举例时例句要短，并附中文翻译。
        - 可以使用粗体和列表，不要使用标题、表格和代码块。
        """

    /// The question the Grammar button asks about a selection, naming the
    /// sentence it was selected in: there may be several in the thread.
    static func grammarQuestion(about text: String, in sentence: String) -> String {
        "「\(text)」在「\(sentence)」这句话里是什么语法？请说明它的接续、含义和用法。"
    }

    /// What the panel showed about a sentence, as the assistant's turn after it.
    static func breakdown(chinese: String, words: [AnalyzedWord]) -> String {
        var lines: [String] = []
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

    /// The thread so far, then the new question. Each sentence is a turn of
    /// the user's with its analysis as the answer, so that a question sits
    /// after the sentence it was asked about. Lookups stay out, and so does
    /// an analysis or a question that got nothing back: there is nothing to
    /// refer back to, and two user turns in a row is an error to some chat
    /// templates.
    static func messages(asking question: String, after thread: [SentenceAnalyzer.ThreadItem]) -> [[String: String]] {
        var messages = [["role": "system", "content": instructions]]
        for item in thread {
            switch item {
            case .analysis(let analysis) where !analysis.isEmpty:
                messages.append(["role": "user", "content": "句子：\(analysis.sentence)"])
                messages.append([
                    "role": "assistant", "content": breakdown(chinese: analysis.chinese, words: analysis.words),
                ])
            case .followUp(let followUp) where !followUp.answer.isEmpty:
                messages.append(["role": "user", "content": followUp.question])
                messages.append(["role": "assistant", "content": followUp.answer])
            default:
                break
            }
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
