import SwiftUI
import XCTest
@testable import LiveTransMobile

/// The sheet over the captions: which sentence it is turned to as the
/// buttons are pressed, and the thread as the phone draws it.
@MainActor
final class AnalysisSheetTests: XCTestCase {
    private var captions: [Caption] = []

    override func setUp() async throws {
        captions = PlaybackModel.captions(of: try VideoBundle.decode(Data(Fixtures.bundle.utf8)))
    }

    func testTheSheetOpensOnTheSentenceAskedForAndTurnsToTheNextOne() {
        let model = AnalysisSheetModel(analyzer: SentenceAnalyzer(makeClient: { nil }))
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.shown)
        model.open(captions[0])
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.shown?.captionID, 0)
        XCTAssertEqual(model.shown?.sentence, captions[0].japanese)
        model.open(captions[1])
        XCTAssertEqual(model.shown?.captionID, 1)
        XCTAssertEqual(model.analyzer.analyses.map(\.captionID), [0, 1], "the thread keeps both")
        // Asked about again, a sentence is turned to, not added.
        model.open(captions[0])
        XCTAssertEqual(model.shown?.captionID, 0)
        XCTAssertEqual(model.analyzer.analyses.count, 2)
        // Swiped down, the sheet keeps its thread for the next press.
        model.isPresented = false
        model.open(captions[1])
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.analyzer.analyses.count, 2)
        // Leaving the video takes the thread with it.
        model.end()
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.analyzer.analyses.isEmpty)
        XCTAssertNil(model.shown)
    }

    /// The sheet with a sentence explained, a word looked up and a question
    /// answered by a scripted server, rendered to a picture for a look
    /// (SNAPSHOT_DIR) and checked to have taken its room.
    func testTheSheetDrawsTheThread() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedLLM.self]
        let session = URLSession(configuration: configuration)
        ScriptedLLM.answers = [Self.analysis, Self.entry, Self.answer]
        let analyzer = SentenceAnalyzer(makeClient: {
            AnalysisClient(baseURL: URL(string: "http://llm.test/v1")!, model: "test", session: session)
        })
        let model = AnalysisSheetModel(analyzer: analyzer)
        model.open(captions[0])
        try await settle { analyzer.analyzing == nil }
        XCTAssertEqual(model.shown?.phase, .done)
        XCTAssertEqual(model.shown?.chinese, "窗外有鸟在唱歌。")
        XCTAssertEqual(model.shown?.words.filter { !$0.isPunctuation }.count, 7)
        XCTAssertEqual(model.shown?.ruby.compactMap(\.reading).first, "まど", "the LLM's readings once done")
        analyzer.lookUp("歌っている")
        try await settle { analyzer.lookingUp == nil }
        XCTAssertEqual(analyzer.lookups.first?.entries.map(\.headword), ["歌う"])
        XCTAssertEqual(analyzer.lookups.first?.grammar.count, 1)
        analyzer.ask("「ている」是什么意思？")
        try await settle { !analyzer.isAnswering }
        XCTAssertEqual(analyzer.followUps.first?.answer.isEmpty, false)
        XCTAssertEqual(analyzer.thread.count, 3)

        let sheet = AnalysisView()
            .environment(analyzer)
            .frame(width: 390, height: 900)
            .background(Color(.systemBackground))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 390)
        XCTAssertEqual(image.size.height, 900)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/phone-analysis.png"))
        }
    }

    /// Waits for the analyzer's task, which runs on the main actor between
    /// turns of this one.
    private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<300 where !done() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(done(), "the server's answer arrived")
    }

    // Invented sentences, as the fixtures are.
    private static let analysis = """
        {"zh": "窗外有鸟在唱歌。"}
        {"w": "窓", "r": "まど", "base": "窓", "pos": "名词", "change": "", "meaning": "窗户"}
        {"w": "の", "r": "の", "base": "の", "pos": "助词", "change": "", "meaning": "的"}
        {"w": "外", "r": "そと", "base": "外", "pos": "名词", "change": "", "meaning": "外面"}
        {"w": "で", "r": "で", "base": "で", "pos": "助词", "change": "", "meaning": "在（动作发生的场所）"}
        {"w": "鳥", "r": "とり", "base": "鳥", "pos": "名词", "change": "", "meaning": "鸟"}
        {"w": "が", "r": "が", "base": "が", "pos": "助词", "change": "", "meaning": "主语标记"}
        {"w": "歌っている", "r": "うたっている", "base": "歌う", "pos": "五段动词・自动词", \
        "change": "歌う → て形 歌って → 歌っている（正在进行）", "meaning": "正在唱歌"}
        {"w": "。", "r": "", "base": "", "pos": "", "change": "", "meaning": ""}
        """

    private static let entry = """
        {"head": "歌う", "r": "うたう", "tags": ["常用词", "JLPT N4"]}
        {"pos": "五段动词・自动词", "def": "唱歌；吟咏", "note": "", "ex": "彼女は毎朝歌う。", "ex_zh": "她每天早上唱歌。", "here": true}
        {"grammar": "ている", "explain": "动词て形后接「いる」，表示动作正在进行或状态的持续。"}
        """

    private static let answer = """
        「ている」接在动词て形之后，表示**正在进行**的动作，或动作结束后留下的状态。
        - 鳥が歌っている：鸟正在唱歌。
        """
}

/// Answers each request with the next of `answers`, streamed the way an
/// OpenAI-compatible server does; HTTP 500 once they run out.
private final class ScriptedLLM: URLProtocol {
    private static let lock = NSLock()
    private static var _answers: [String] = []

    static var answers: [String] {
        get { lock.withLock { _answers } }
        set { lock.withLock { _answers = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer: String? = Self.lock.withLock { Self._answers.isEmpty ? nil : Self._answers.removeFirst() }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer == nil ? 500 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let answer {
            // The whole answer in one chunk: the parsers split it into lines.
            let chunk = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": answer]]]])
            var body = Data("data: ".utf8)
            body.append(chunk)
            body.append(Data("\n\ndata: [DONE]\n\n".utf8))
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
