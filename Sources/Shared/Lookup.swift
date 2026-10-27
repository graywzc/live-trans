import Foundation

/// One meaning of a dictionary entry's word.
struct Sense: Equatable, Identifiable {
    /// Its place among the meanings of its word.
    var id: Int
    var partOfSpeech: String
    var definition: String
    var note = ""
    var example = ""
    var exampleChinese = ""
    /// The meaning the word has in the sentence being read.
    var appliesHere = false
}

/// A word as a dictionary has it: jisho.org's headword, reading, tags and
/// numbered meanings, written by the LLM instead of looked up.
struct DictionaryEntry: Equatable, Identifiable {
    let id: Int
    var headword: String
    var reading: String
    var tags: [String] = []
    var senses: [Sense] = []
}

struct GrammarPoint: Equatable, Identifiable {
    let id: Int
    var form: String
    var explanation: String
}

/// Text selected in the analysis and looked up, and what has arrived about it
/// so far: an entry per word, then the grammar in the selection as it stands.
struct Lookup: Equatable, Identifiable {
    let id: Int
    let text: String
    /// The sentence it was selected while reading, which goes along with it.
    var sentence = ""
    var entries: [DictionaryEntry] = []
    var grammar: [GrammarPoint] = []
    var error: String?

    var isEmpty: Bool {
        entries.isEmpty && grammar.isEmpty
    }

    mutating func apply(_ event: LookupEvent) {
        switch event {
        case .entry(let headword, let reading, let tags):
            entries.append(DictionaryEntry(id: entries.count, headword: headword, reading: reading, tags: tags))
        case .sense(var sense):
            // A meaning belongs to the word above it; one with no word is
            // not worth guessing a word for.
            guard !entries.isEmpty else { return }
            sense.id = entries[entries.count - 1].senses.count
            entries[entries.count - 1].senses.append(sense)
        case .grammar(let form, let explanation):
            grammar.append(GrammarPoint(id: grammar.count, form: form, explanation: explanation))
        }
    }
}

enum LookupEvent: Equatable {
    case entry(headword: String, reading: String, tags: [String])
    case sense(Sense)
    case grammar(form: String, explanation: String)
}

/// What the LLM is asked for when a selection is looked up, and how its
/// answer is read. Lines of JSON like the analysis, for the same reason: the
/// headword shows after a second, not the whole entry after four.
enum LookupFormat {
    static let instructions = """
        你是日语词典，体例参照 jisho.org，释义和说明用简体中文。用户在阅读一句日语的讲解时选中了一段文字，\
        请为选中的文字编写词典条目。
        逐行输出 JSON（每行一个完整的 JSON 对象，不要输出其他任何内容，不要使用 Markdown 代码块）。
        每个词条先输出一行词头：
        {"head": "原形（辞书形）的通常写法", "r": "平假名读音", "tags": ["标签"]}
        tags 如「常用词」「JLPT N5」「敬语」「口语」，没有则为空数组。
        接着按常用程度输出该词的各个义项，每个义项一行，最多五个：
        {"pos": "词性", "def": "释义，近义的说法用；隔开", "note": "用法说明，没有则为空字符串", \
        "ex": "简短的日语例句", "ex_zh": "例句的中文翻译", "here": true 或 false}
        here 表示该义项是否是这个词在用户所读句子中的意思，每个词条至多一个 true。
        所有词条之后，如果选中的文字含有活用、助词、助动词、句型等语法现象，每个语法点输出一行：
        {"grammar": "语法点的名称或形式", "explain": "接续方式、含义和用法的说明"}
        要求：
        - 选中的是活用形时，词头用原形，活用的过程放在语法点里说明。
        - 选中的是短语或含有多个词时，每个实词各出一个词条，助词和助动词放在语法点里说明。
        - 选中的不是日语（例如中文的语法术语）时，把它当作日语语法术语来解释：不输出词条，只输出语法点。
        - 只列词典里确实有的义项，宁缺毋滥；ex 必须是用到该词这个义项的句子。
        - 同一写法有不同读音、不同意思的词（如「辛い」读からい和つらい）各出一个词条，句中用到的那个排在最前。
        - 选中的文字就是原形、不含语法现象时，不输出语法点。
        - 动词的类别要准确：「食べる」「見る」是一段动词，「行く」「帰る」是五段动词。
        - pos 用简体中文并写明类别，例如「五段动词・自动词」「イ形容词」「名词・サ变动词」。
        """

    /// The sentence goes along so that the entry can say which meaning is
    /// the one in it, and read 辛い the way the sentence does.
    static func messages(lookingUp text: String, in sentence: String) -> [[String: String]] {
        [
            ["role": "system", "content": instructions],
            ["role": "user", "content": "句子：\(sentence)\n选中的文字：\(text)"],
        ]
    }

    /// Anything that is not one of the three kinds of line is dropped.
    static func event(fromLine line: String) -> LookupEvent? {
        struct Line: Decodable {
            var head: String?
            var r: String?
            var tags: [String]?
            var pos: String?
            var def: String?
            var note: String?
            var ex: String?
            var ex_zh: String?
            var here: Bool?
            var grammar: String?
            var explain: String?
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let parsed = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8))
        else { return nil }
        if let headword = parsed.head, !headword.isEmpty {
            return .entry(headword: headword, reading: parsed.r ?? "", tags: parsed.tags ?? [])
        }
        if let definition = parsed.def, !definition.isEmpty {
            return .sense(Sense(
                id: 0, partOfSpeech: parsed.pos ?? "", definition: definition, note: parsed.note ?? "",
                example: parsed.ex ?? "", exampleChinese: parsed.ex_zh ?? "", appliesHere: parsed.here ?? false
            ))
        }
        if let form = parsed.grammar, !form.isEmpty {
            return .grammar(form: form, explanation: parsed.explain ?? "")
        }
        return nil
    }
}

/// Turns the streamed answer, which arrives in arbitrary pieces, into events.
struct LookupStreamParser {
    private var pending = ""

    mutating func consume(content: String) -> [LookupEvent] {
        pending += content
        var events: [LookupEvent] = []
        while let newline = pending.firstIndex(of: "\n") {
            if let event = LookupFormat.event(fromLine: String(pending[..<newline])) {
                events.append(event)
            }
            pending = String(pending[pending.index(after: newline)...])
        }
        return events
    }

    /// The last line usually ends without a newline.
    mutating func finish() -> [LookupEvent] {
        defer { pending = "" }
        return LookupFormat.event(fromLine: pending).map { [$0] } ?? []
    }
}
