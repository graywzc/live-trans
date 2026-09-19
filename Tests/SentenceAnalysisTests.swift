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
        XCTAssertEqual(analyzer.phase, .running)
        var snappedPartial = false
        for _ in 0..<600 where analyzer.phase == .running {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !snappedPartial, analyzer.words.count >= 3 {
                snappedPartial = true
                snapshot(window, "analysis-streaming")
            }
        }
        XCTAssertEqual(analyzer.phase, .done)
        XCTAssertFalse(analyzer.chinese.isEmpty)
        XCTAssertEqual(analyzer.words.map(\.surface).joined(), japanese)
        XCTAssertTrue(analyzer.ruby.contains(RubyToken(base: "辛", reading: "から")))
        try await Task.sleep(nanoseconds: 300_000_000)
        snapshot(window, "analysis-done")
    }

    private func snapshot(_ window: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
