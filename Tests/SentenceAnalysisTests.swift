import SwiftUI
import XCTest
@testable import LiveTrans

final class SentenceAnalysisTests: XCTestCase {
    private let sentence = "昨日は食べられなかった。"
    private let answer = """
        {"zh": "昨天没能吃。"}
        {"w": "昨日", "r": "きのう", "base": "昨日", "pos": "名词", "change": "", "meaning": "昨天"}
        {"w": "は", "r": "は", "base": "は", "pos": "助词", "change": "", "meaning": "提示主题"}
        {"w": "食べられなかった", "r": "たべられなかった", "base": "食べる", "pos": "动词", "change": "食べる → 可能形 → 否定 → 过去", "meaning": "没能吃"}
        {"w": "。", "r": "", "base": "", "pos": "", "change": "", "meaning": ""}
        """

    private func events(from content: String, pieceLength: Int) -> [AnalysisEvent] {
        var parser = AnalysisStreamParser()
        var events: [AnalysisEvent] = []
        var rest = Substring(content)
        while !rest.isEmpty {
            events += parser.consume(content: String(rest.prefix(pieceLength)))
            rest = rest.dropFirst(pieceLength)
        }
        return events + parser.finish()
    }

    private func words(_ events: [AnalysisEvent]) -> [AnalyzedWord] {
        events.compactMap { if case .word(let word) = $0 { word } else { nil } }
    }

    func testLinesAreParsedHoweverTheStreamIsCut() {
        let whole = events(from: answer, pieceLength: answer.count)
        XCTAssertEqual(whole.first, .translation("昨天没能吃。"))
        XCTAssertEqual(words(whole).map(\.surface), ["昨日", "は", "食べられなかった", "。"])
        XCTAssertEqual(words(whole)[2].base, "食べる")
        XCTAssertEqual(words(whole)[2].change, "食べる → 可能形 → 否定 → 过去")
        XCTAssertEqual(words(whole).map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(words(whole).map(\.isPunctuation), [false, false, false, true])

        XCTAssertEqual(events(from: answer, pieceLength: 1), whole)
        XCTAssertEqual(events(from: answer, pieceLength: 7), whole)
    }

    func testAnythingElseInTheAnswerIsDropped() {
        let noisy = "```json\n<think>hmm</think>\n" + answer + "\n```\n以上です。"
        XCTAssertEqual(events(from: noisy, pieceLength: 5), events(from: answer, pieceLength: 5))
    }

    func testServerSentEventsCarryTheContent() {
        var parser = AnalysisStreamParser()
        XCTAssertEqual(parser.consume(sseLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), [])
        XCTAssertEqual(parser.consume(sseLine: #"data: {"choices":[{"delta":{"content":"{\"zh\": \"你"}}]}"#), [])
        XCTAssertEqual(
            parser.consume(sseLine: #"data: {"choices":[{"delta":{"content":"好\"}\n"}}]}"#),
            [.translation("你好")]
        )
        // Reasoning is not content, whatever the server does with the request
        // not to think.
        XCTAssertEqual(parser.consume(sseLine: #"data: {"choices":[{"delta":{"reasoning_content":"{\"zh\": \"x\"}\n"}}]}"#), [])
        XCTAssertEqual(parser.consume(sseLine: "data: [DONE]"), [])
        XCTAssertEqual(parser.consume(sseLine: ": keep-alive"), [])
    }

    /// Stateless: the request is the instructions and the one sentence.
    func testRequestCarriesOnlyTheSentence() throws {
        let client = AnalysisClient(baseURL: URL(string: "http://gpu:8020/v1")!, model: "qwen")
        for sentence in ["最初の文。", "次の文。"] {
            let request = client.request(for: sentence)
            XCTAssertEqual(request.url?.absoluteString, "http://gpu:8020/v1/chat/completions")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "qwen")
            XCTAssertEqual(body["stream"] as? Bool, true)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertEqual(messages[0]["content"], AnalysisFormat.instructions)
            XCTAssertEqual(messages[1]["content"], sentence)
        }
        // Nor does the answer land in a cache on disk.
        XCTAssertEqual(client.session.configuration.urlCache?.diskCapacity ?? 0, 0)
    }

    /// A follow-up carries what the panel shows: each sentence analyzed,
    /// with the questions asked after it, since the server has kept none of it.
    func testFollowUpCarriesTheAnalysesAndTheEarlierQuestions() throws {
        let all = events(from: answer, pieceLength: 50)
        var first = Analysis(id: 0, captionID: 3, sentence: sentence, tokenizerRuby: [])
        first.chinese = "昨天没能吃。"
        first.words = words(all)
        first.phase = .done
        var second = Analysis(id: 3, captionID: 4, sentence: "次", tokenizerRuby: [])
        second.chinese = "下一个"
        second.phase = .done
        let thread: [SentenceAnalyzer.ThreadItem] = [
            .analysis(first),
            .followUp(FollowUp(id: 1, question: "为什么用は？", raw: "<think>は…</think>\n表示**对比**。")),
            .lookup(Lookup(id: 2, text: "昨日", sentence: sentence)),
            .analysis(second),
            .followUp(FollowUp(id: 4, question: "没有回答的问题", error: "timed out")),
            .analysis(Analysis(id: 5, captionID: 5, sentence: "失敗", tokenizerRuby: [], phase: .failed("timed out"))),
        ]
        let messages = FollowUpFormat.messages(asking: "那が呢？", after: thread)
        XCTAssertEqual(
            messages.map { $0["role"] }, ["system", "user", "assistant", "user", "assistant", "user", "assistant", "user"]
        )
        XCTAssertEqual(messages[0]["content"], FollowUpFormat.instructions)
        XCTAssertEqual(messages[1]["content"], "句子：\(sentence)")
        let breakdown = try XCTUnwrap(messages[2]["content"])
        XCTAssertTrue(breakdown.hasPrefix("翻译：昨天没能吃。"))
        XCTAssertTrue(breakdown.contains("食べられなかった｜たべられなかった｜食べる｜动词｜食べる → 可能形 → 否定 → 过去｜没能吃"))
        XCTAssertTrue(breakdown.contains("昨日｜きのう｜昨日｜名词｜—｜昨天"))
        XCTAssertFalse(breakdown.contains("。｜"))
        XCTAssertEqual(messages[3]["content"], "为什么用は？")
        XCTAssertEqual(messages[4]["content"], "表示**对比**。")
        XCTAssertEqual(messages[5]["content"], "句子：次")
        XCTAssertEqual(messages[6]["content"], "翻译：下一个")
        XCTAssertEqual(messages[7]["content"], "那が呢？")

        let client = AnalysisClient(baseURL: URL(string: "http://gpu:8020/v1")!, model: "qwen")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(client.request(messages: messages).httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["messages"] as? [[String: String]], messages)
    }

    func testThinkingIsNotPartOfAnAnswer() {
        XCTAssertEqual(FollowUpFormat.visible("表示对比。\n"), "表示对比。")
        XCTAssertEqual(FollowUpFormat.visible("<think>\nは or が"), "")
        XCTAssertEqual(FollowUpFormat.visible("<think>\nは or が\n</think>\n\n表示对比。"), "表示对比。")
        XCTAssertEqual(FollowUpFormat.visible("「<think>」不是日语。"), "「<think>」不是日语。")
    }

    func testTheLLMsReadingsGoOverTheKanji() throws {
        let tokens = try XCTUnwrap(Furigana.annotate(sentence, words: words(events(from: answer, pieceLength: 50))))
        XCTAssertEqual(tokens.map(\.base), ["昨日", "は", "食", "べられなかった", "。"])
        XCTAssertEqual(tokens.map(\.reading), ["きのう", nil, "た", nil, nil])
        XCTAssertTrue(tokens[4].gluesToPrevious)
        XCTAssertTrue(tokens[3].continuesWord)
    }

    func testABreakdownThatIsNotTheSentenceIsNotUsedForReadings() {
        let all = words(events(from: answer, pieceLength: 50))
        XCTAssertNil(Furigana.annotate(sentence, words: Array(all.dropLast())))
        XCTAssertNil(Furigana.annotate(sentence, words: []))
        var romanized = all
        romanized[0].reading = "kinou"
        XCTAssertEqual(Furigana.annotate(sentence, words: romanized)?.first, RubyToken(base: "昨日"))
    }
}

/// The analyzer against a server that answers from a script.
@MainActor
final class FollowUpTests: XCTestCase {
    private var analyzer: SentenceAnalyzer!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedServer.self]
        var client = AnalysisClient(baseURL: URL(string: "http://gpu:8020/v1")!, model: "qwen")
        client.session = URLSession(configuration: configuration)
        analyzer = SentenceAnalyzer { client }
        ScriptedServer.requests = []
        ScriptedServer.answers = []
        ScriptedServer.analyses = []
        ScriptedServer.entries = []
    }

    private func analyze(_ japanese: String, id: Int) async throws {
        ScriptedServer.analyses.append(#"{"zh": "译文"}"# + "\n" + #"{"w": "\#(japanese)", "r": "", "base": "\#(japanese)", "pos": "名词", "change": "", "meaning": "意思"}"#)
        analyzer.analyze(Caption(id: id, japanese: japanese, ruby: [], english: ""))
        try await settle()
        XCTAssertEqual(analyzer.analyses.last?.phase, .done)
    }

    private func settle() async throws {
        for _ in 0..<200 where analyzer.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func contents(ofRequest index: Int) throws -> [String] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: ScriptedServer.requests[index]) as? [String: Any])
        return try XCTUnwrap(body["messages"] as? [[String: String]]).compactMap { $0["content"] }
    }

    func testQuestionsAreAnsweredInTurnAndGoWithTheSentence() async throws {
        analyzer.ask("还没有句子")
        XCTAssertTrue(analyzer.followUps.isEmpty)

        try await analyze("最初", id: 1)
        ScriptedServer.answers = ["第一个**回答**", "第二个回答"]
        analyzer.ask("  第一个问题\n")
        XCTAssertTrue(analyzer.isAnswering)
        XCTAssertFalse(analyzer.canAsk)
        try await settle()
        analyzer.ask("第二个问题")
        try await settle()
        XCTAssertEqual(analyzer.followUps.map(\.question), ["第一个问题", "第二个问题"])
        XCTAssertEqual(analyzer.followUps.map(\.answer), ["第一个**回答**", "第二个回答"])
        XCTAssertEqual(analyzer.followUps.map(\.id), [1, 2])

        let second = try contents(ofRequest: 2)
        XCTAssertEqual(second[1], "句子：最初")
        XCTAssertEqual(Array(second.dropFirst(3)), ["第一个问题", "第一个**回答**", "第二个问题"])

        // The next sentence joins the same conversation.
        try await analyze("次", id: 2)
        XCTAssertEqual(analyzer.followUps.count, 2)
        XCTAssertEqual(analyzer.thread.map(\.id), [0, 1, 2, 3])
        ScriptedServer.answers = ["第三个回答"]
        analyzer.ask("第三个问题")
        try await settle()
        let third = try contents(ofRequest: 4)
        XCTAssertEqual(third.count, 10)
        XCTAssertEqual(third[1], "句子：最初")
        XCTAssertEqual(third[7], "句子：次")
        XCTAssertEqual(third.last, "第三个问题")
    }

    func testGrammarIsAskedAsAQuestionAboutTheSelection() async throws {
        analyzer.askAboutGrammar("食べて")
        XCTAssertTrue(analyzer.followUps.isEmpty)

        try await analyze("最初", id: 1)
        ScriptedServer.answers = ["て形"]
        analyzer.askAboutGrammar(" 食べて\n")
        try await settle()
        XCTAssertEqual(
            analyzer.followUps.map(\.question), [FollowUpFormat.grammarQuestion(about: "食べて", in: "最初")]
        )
        XCTAssertEqual(analyzer.followUps.first?.answer, "て形")
        let request = try contents(ofRequest: 1)
        XCTAssertEqual(request[1], "句子：最初")
        XCTAssertTrue(request.last!.contains("「食べて」"))

        // Selected under the first of two sentences, it names the first.
        try await analyze("次", id: 2)
        ScriptedServer.answers = ["名词"]
        analyzer.askAboutGrammar("最初", under: 0)
        try await settle()
        XCTAssertEqual(analyzer.followUps.last?.question, FollowUpFormat.grammarQuestion(about: "最初", in: "最初"))
    }

    func testAFailedQuestionCanBeAskedAgain() async throws {
        try await analyze("最初", id: 1)
        analyzer.ask("问题")
        try await settle()
        XCTAssertNotNil(analyzer.followUps.first?.error)
        XCTAssertTrue(analyzer.canAsk)

        ScriptedServer.answers = ["回答"]
        analyzer.retryFollowUp()
        try await settle()
        XCTAssertEqual(analyzer.followUps.map(\.answer), ["回答"])
        XCTAssertNil(analyzer.followUps[0].error)
        XCTAssertEqual(try contents(ofRequest: 2).last, "问题")
    }

    func testAQuestionWaitsForTheSentenceBeingAnalyzed() async throws {
        try await analyze("最初", id: 1)
        ScriptedServer.analyses = [#"{"zh": "译文"}"#]
        analyzer.analyze(Caption(id: 2, japanese: "次", ruby: [], english: ""))
        XCTAssertFalse(analyzer.canAsk)
        try await settle()
        XCTAssertTrue(analyzer.canAsk)
    }

    func testAnotherSentenceDoesNotStopTheAnswer() async throws {
        try await analyze("最初", id: 1)
        ScriptedServer.answers = ["回答"]
        analyzer.ask("问题")
        try await analyze("次", id: 2)
        XCTAssertEqual(analyzer.followUps.map(\.answer), ["回答"])
        XCTAssertEqual(analyzer.analyses.map(\.sentence), ["最初", "次"])
    }

    func testACaptionAnalyzedBeforeIsShownNotAnalyzedAgain() async throws {
        try await analyze("最初", id: 1)
        try await analyze("次", id: 2)
        XCTAssertNil(analyzer.revealed)
        analyzer.analyze(Caption(id: 1, japanese: "最初", ruby: [], english: ""))
        XCTAssertEqual(analyzer.revealed?.id, 0)
        XCTAssertFalse(analyzer.isBusy)
        analyzer.analyze(Caption(id: 1, japanese: "最初", ruby: [], english: ""))
        XCTAssertEqual(analyzer.revealed, SentenceAnalyzer.Reveal(id: 0, serial: 2))
        XCTAssertEqual(analyzer.analyses.count, 2)
        XCTAssertEqual(ScriptedServer.requests.count, 2)
        XCTAssertTrue(analyzer.hasAnalyzed(Caption(id: 2, japanese: "次", ruby: [], english: "")))
        XCTAssertFalse(analyzer.hasAnalyzed(Caption(id: 3, japanese: "次", ruby: [], english: "")))
    }

    func testAFailedSentenceIsAnalyzedAgainInItsPlace() async throws {
        analyzer.analyze(Caption(id: 1, japanese: "最初", ruby: [], english: ""))
        try await settle()
        guard case .failed = analyzer.analyses.first?.phase else { return XCTFail("should have failed") }
        try await analyze("次", id: 2)
        ScriptedServer.analyses = [#"{"zh": "译文"}"#]
        analyzer.analyze(Caption(id: 1, japanese: "最初", ruby: [], english: ""))
        try await settle()
        XCTAssertEqual(analyzer.analyses.map(\.phase), [.done, .done])
        XCTAssertEqual(analyzer.analyses.map(\.sentence), ["最初", "次"])
    }

    func testAnAnalysisStoppedBeforeItsFirstLineGoes() async throws {
        try await analyze("最初", id: 1)
        analyzer.analyze(Caption(id: 2, japanese: "次", ruby: [], english: ""))
        analyzer.cancel()
        XCTAssertEqual(analyzer.analyses.map(\.sentence), ["最初"])
        XCTAssertTrue(analyzer.canAsk)
    }

    func testClearingStartsOver() async throws {
        try await analyze("最初", id: 1)
        ScriptedServer.answers = ["回答"]
        analyzer.ask("问题")
        try await settle()
        analyzer.clear()
        XCTAssertTrue(analyzer.thread.isEmpty)
        try await analyze("次", id: 2)
        ScriptedServer.answers = ["回答"]
        analyzer.ask("问题")
        try await settle()
        let request = try contents(ofRequest: 3)
        XCTAssertEqual(request.count, 4)
        XCTAssertFalse(request.joined().contains("最初"))
    }
}

extension FollowUpTests {
    private static let entry = #"{"head": "最初", "r": "さいしょ", "tags": []}"# + "\n"
        + #"{"pos": "名词", "def": "最初；起初", "here": true}"#

    func testLookupsGoIntoTheThreadWithTheQuestions() async throws {
        analyzer.lookUp("还没有句子")
        XCTAssertTrue(analyzer.lookups.isEmpty)

        try await analyze("最初", id: 1)
        ScriptedServer.entries = [Self.entry, #"{"grammar": "名词", "explain": "…"}"#]
        ScriptedServer.answers = ["回答"]
        analyzer.lookUp(" 最初\n")
        XCTAssertEqual(analyzer.lookingUp, 1)
        // Neither waits for the other.
        XCTAssertTrue(analyzer.canAsk)
        analyzer.ask("问题")
        try await settle()
        analyzer.lookUp("名词")
        try await settle()

        XCTAssertEqual(analyzer.thread.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(analyzer.lookups.map(\.text), ["最初", "名词"])
        XCTAssertEqual(analyzer.lookups[0].entries.first?.senses.map(\.definition), ["最初；起初"])
        XCTAssertEqual(analyzer.lookups[1].grammar.map(\.form), ["名词"])
        XCTAssertEqual(analyzer.followUps.map(\.answer), ["回答"])
        XCTAssertNil(analyzer.lookingUp)

        // The selection and the sentence, and nothing of the thread.
        XCTAssertEqual(try contents(ofRequest: 3), [LookupFormat.instructions, "句子：最初\n选中的文字：名词"])

        // A selection goes with the sentence it is under.
        try await analyze("次", id: 2)
        ScriptedServer.entries = [Self.entry, Self.entry, Self.entry]
        analyzer.lookUp("甲", under: 1)
        try await settle()
        analyzer.lookUp("乙", under: 5)
        try await settle()
        analyzer.lookUp("丙")
        try await settle()
        XCTAssertEqual(analyzer.lookups.suffix(3).map(\.sentence), ["最初", "次", "次"])
        XCTAssertEqual(try contents(ofRequest: 5).last, "句子：最初\n选中的文字：甲")
        XCTAssertEqual(try contents(ofRequest: 6).last, "句子：次\n选中的文字：乙")
    }

    func testAFailedLookupCanBeRetried() async throws {
        try await analyze("最初", id: 1)
        ScriptedServer.entries = ["好的，以下是词条。"]
        analyzer.lookUp("最初")
        try await settle()
        XCTAssertNotNil(analyzer.lookups.first?.error)

        ScriptedServer.entries = [Self.entry]
        analyzer.retryLookup(1)
        try await settle()
        XCTAssertEqual(analyzer.lookups.count, 1)
        XCTAssertNil(analyzer.lookups[0].error)
        XCTAssertEqual(analyzer.lookups[0].entries.map(\.headword), ["最初"])
    }

    func testTheNextLookupStopsTheOneBeingWritten() async throws {
        try await analyze("最初", id: 1)
        ScriptedServer.entries = [Self.entry, Self.entry]
        analyzer.lookUp("最")
        analyzer.lookUp("初")
        XCTAssertEqual(analyzer.lookingUp, 2)
        try await settle()
        XCTAssertNil(analyzer.lookups[0].error)
        XCTAssertEqual(analyzer.lookups[1].entries.count, 1)
    }
}

/// Answers each request with the next of `answers`, streamed the way an
/// OpenAI-compatible server does; HTTP 500 once they run out. An analysis, a
/// lookup and a question draw from separate scripts: a cancelled question may or may not
/// reach the server before the analysis that replaced it, and must not be able
/// to take its answer.
private final class ScriptedServer: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [Data] = []
    private static var _answers: [String] = []
    private static var _analyses: [String] = []
    private static var _entries: [String] = []

    static var requests: [Data] {
        get { lock.withLock { _requests } }
        set { lock.withLock { _requests = newValue } }
    }
    static var answers: [String] {
        get { lock.withLock { _answers } }
        set { lock.withLock { _answers = newValue } }
    }
    static var analyses: [String] {
        get { lock.withLock { _analyses } }
        set { lock.withLock { _analyses = newValue } }
    }

    static var entries: [String] {
        get { lock.withLock { _entries } }
        set { lock.withLock { _entries = newValue } }
    }

    private static func take(for body: Data) -> String? {
        lock.withLock {
            _requests.append(body)
            let text = String(decoding: body, as: UTF8.self)
            // JSON escapes what is not ASCII, or may.
            let isLookup = text.contains("jisho.org")
            if isLookup {
                return _entries.isEmpty ? nil : _entries.removeFirst()
            }
            if text.contains("JSON") {
                return _analyses.isEmpty ? nil : _analyses.removeFirst()
            }
            return _answers.isEmpty ? nil : _answers.removeFirst()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        let answer = Self.take(for: body)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer == nil ? 500 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in (answer ?? "").map(String.init) {
            let chunk = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": piece]]]])
            client?.urlProtocol(self, didLoad: Data("data: ".utf8) + chunk + Data("\n\n".utf8))
        }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The panel as it is drawn, fed by the real server when there is one:
///
///     TEST_RUNNER_ANALYSIS_URL=http://gpu:8020/v1 TEST_RUNNER_ANALYSIS_MODEL=qwen3.8-27b \
///     TEST_RUNNER_SNAPSHOT_DIR=/tmp xcodebuild test ... -only-testing:LiveTransTests/AnalysisPanelTests
@MainActor
final class AnalysisPanelTests: XCTestCase {
    func testPanelShowsTheAnalysisOfACaption() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["ANALYSIS_URL"], let url = URL(string: address),
              let model = environment["ANALYSIS_MODEL"]
        else { throw XCTSkip("no LLM server given") }

        let analyzer = SentenceAnalyzer { AnalysisClient(baseURL: url, model: model) }
        let panel = SidePanel()
        panel.show(.analysis)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SidePanelView()
            .environment(analyzer).environment(panel).environment(JishoBrowser())
            .frame(width: 640, height: 720)
            .background(Color.black)
            .preferredColorScheme(.dark))
        window.orderFrontRegardless()
        defer { window.close() }

        let japanese = "このラーメンは辛くて、全部食べられなかったんだよね。"
        // The tokenizer can't tell spicy from painful.
        XCTAssertTrue(Furigana.annotate(japanese).contains(RubyToken(base: "辛", reading: "つら")))
        analyzer.analyze(Caption(id: 7, japanese: japanese, ruby: Furigana.annotate(japanese), english: ""))
        XCTAssertEqual(analyzer.analyses.last?.phase, .running)
        var snappedPartial = false
        for _ in 0..<600 where analyzer.analyzing != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !snappedPartial, (analyzer.analyses.last?.words.count ?? 0) >= 3 {
                snappedPartial = true
                snapshot(window, "analysis-streaming")
            }
        }
        let analysis = try XCTUnwrap(analyzer.analyses.last)
        XCTAssertEqual(analysis.phase, .done)
        XCTAssertFalse(analysis.chinese.isEmpty)
        XCTAssertEqual(analysis.words.map(\.surface).joined(), japanese)
        XCTAssertTrue(analysis.ruby.contains(RubyToken(base: "辛", reading: "から")))
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot(window, "analysis-done")

        // Select the word in its row of the table, as a drag over it would,
        // and click the button that comes up over it.
        func textViews(in view: NSView) -> [NSTextView] {
            ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
        }
        let cell = try XCTUnwrap(textViews(in: try XCTUnwrap(window.contentView)).first { $0.string == "食べられなかった" })
        window.makeFirstResponder(cell)
        cell.setSelectedRange(NSRange(location: 0, length: cell.string.utf16.count))
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot(window, "lookup-selected")
        let frame = cell.convert(cell.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: frame.midX - 20, y: frame.maxY + 17), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )), atStart: false)
        }
        while let event = NSApp.nextEvent(
            matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
        XCTAssertNotNil(analyzer.lookingUp)
        for _ in 0..<600 where analyzer.lookingUp != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let lookup = try XCTUnwrap(analyzer.lookups.first)
        XCTAssertEqual(lookup.text, "食べられなかった")
        XCTAssertNil(lookup.error)
        XCTAssertEqual(lookup.entries.first?.headword, "食べる")
        XCTAssertFalse(lookup.grammar.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)
        snapshot(window, "lookup-done")

        analyzer.ask("「辛くて」的て在这里是什么用法？能换成「辛いから」吗？")
        XCTAssertTrue(analyzer.isAnswering)
        var snappedAnswer = false
        for _ in 0..<600 where analyzer.isAnswering {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !snappedAnswer, (analyzer.followUps.last?.answer.count ?? 0) >= 40 {
                snappedAnswer = true
                snapshot(window, "follow-up-streaming")
            }
        }
        let first = try XCTUnwrap(analyzer.followUps.first)
        XCTAssertNil(first.error)
        XCTAssertFalse(first.answer.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)
        snapshot(window, "follow-up-done")

        // Only makes sense to a model that was sent the first question.
        analyzer.ask("把你刚才说的「辛いから」那种说法用到整句里，重写一遍。")
        for _ in 0..<600 where analyzer.isAnswering {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(analyzer.followUps.count, 2)
        XCTAssertTrue(analyzer.followUps[1].answer.contains("から"))
        try await Task.sleep(nanoseconds: 600_000_000)
        snapshot(window, "follow-up-second")

        // The next sentence goes under the first, in the same conversation.
        let next = "でも、スープは最後まで飲んだ。"
        analyzer.analyze(Caption(id: 8, japanese: next, ruby: Furigana.annotate(next), english: ""))
        for _ in 0..<600 where analyzer.analyzing != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(analyzer.analyses.map(\.phase), [.done, .done])
        try await Task.sleep(nanoseconds: 600_000_000)
        snapshot(window, "second-sentence")

        // Only makes sense to a model that was sent both sentences.
        analyzer.ask("这句和上一句是什么关系？上一句没吃完的是什么？")
        for _ in 0..<600 where analyzer.isAnswering {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let third = try XCTUnwrap(analyzer.followUps.last)
        XCTAssertNil(third.error)
        XCTAssertTrue(third.answer.contains("ラーメン") || third.answer.contains("拉面"), third.answer)
        try await Task.sleep(nanoseconds: 600_000_000)
        snapshot(window, "follow-up-across-sentences")

        // The first sentence is still there, above.
        analyzer.analyze(Caption(id: 7, japanese: japanese, ruby: [], english: ""))
        try await Task.sleep(nanoseconds: 800_000_000)
        snapshot(window, "first-sentence-revealed")
    }

    private func snapshot(_ window: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
