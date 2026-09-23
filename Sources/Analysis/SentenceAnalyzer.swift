import Foundation
import Observation

/// An OpenAI-compatible chat endpoint (vLLM, llama.cpp, ollama's /v1), called
/// directly from the app.
///
/// Nothing about an analysis is remembered. A request carries the instructions
/// and the one sentence, and for a follow-up question what the panel is
/// showing about that sentence, for a lookup the selected text; never
/// anything about an earlier sentence. It
/// goes to the inference server itself, not through an agent or a memory
/// layer in front of one; and the session keeps no cache or cookies.
struct AnalysisClient {
    enum ClientError: LocalizedError {
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                "The LLM server returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            }
        }
    }

    /// `http://host:8020/v1`, as OpenAI clients take it.
    let baseURL: URL
    let model: String
    var session = URLSession(configuration: .ephemeral)

    func request(for sentence: String) -> URLRequest {
        request(messages: [
            ["role": "system", "content": AnalysisFormat.instructions],
            ["role": "user", "content": sentence],
        ])
    }

    func request(messages: [[String: String]]) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0,
            // A thinking model would reason for a minute before the first row.
            // vLLM reads this; servers that don't know the field ignore it.
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": messages,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func analyze(_ sentence: String) -> AsyncThrowingStream<AnalysisEvent, Error> {
        var parser = AnalysisStreamParser()
        return stream(request(for: sentence)) { parser.consume(content: $0) } atEnd: { parser.finish() }
    }

    /// A dictionary entry for text selected while reading the sentence.
    func lookUp(_ text: String, in sentence: String) -> AsyncThrowingStream<LookupEvent, Error> {
        var parser = LookupStreamParser()
        return stream(request(messages: LookupFormat.messages(lookingUp: text, in: sentence))) {
            parser.consume(content: $0)
        } atEnd: { parser.finish() }
    }

    /// The answer to a follow-up question, in the pieces it is generated in.
    func answer(_ messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        stream(request(messages: messages)) { [$0] } atEnd: { [] }
    }

    private func stream<Output>(
        _ request: URLRequest,
        each: @escaping (String) -> [Output], atEnd: @escaping () -> [Output]
    ) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines where body.count < 300 {
                            body += line
                        }
                        throw ClientError.badStatus(status, body)
                    }
                    for try await line in bytes.lines {
                        guard let content = ChatStream.content(ofLine: line) else { continue }
                        each(content).forEach { continuation.yield($0) }
                    }
                    atEnd().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The analysis showing in the side panel, with the questions asked about it
/// and the selections looked up in it. There is only ever this one: the next
/// sentence replaces it, questions and all, and it is never written anywhere.
@MainActor
@Observable
final class SentenceAnalyzer {
    enum Phase: Equatable {
        case idle
        /// No LLM server in Settings yet.
        case unconfigured
        case running
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Which caption's button to keep lit.
    private(set) var captionID: Int?
    private(set) var sentence = ""
    private(set) var chinese = ""
    private(set) var words: [AnalyzedWord] = []
    private(set) var followUps: [FollowUp] = []
    private(set) var isAnswering = false
    private(set) var lookups: [Lookup] = []
    /// The lookup whose entry is being written.
    private(set) var lookingUp: Int?
    /// The question being typed. Here rather than in the view, which is gone
    /// while the panel shows Jisho: looking a word up doesn't lose the question.
    var draft = ""

    /// A question needs an analysis to be about, and waits its turn.
    var canAsk: Bool {
        phase == .done && !isAnswering
    }

    /// The tokenizer's readings until the breakdown is complete, then the
    /// LLM's if its words add up to the sentence.
    var ruby: [RubyToken] {
        (phase == .done ? Furigana.annotate(sentence, words: words) : nil) ?? tokenizerRuby
    }

    /// What is under the analysis, in the order it was asked for.
    enum ThreadItem: Identifiable {
        case followUp(FollowUp)
        case lookup(Lookup)

        var id: Int {
            switch self {
            case .followUp(let followUp): followUp.id
            case .lookup(let lookup): lookup.id
            }
        }
    }

    var thread: [ThreadItem] {
        (followUps.map(ThreadItem.followUp) + lookups.map(ThreadItem.lookup)).sorted { $0.id < $1.id }
    }

    private var tokenizerRuby: [RubyToken] = []
    /// Questions and lookups are numbered in one sequence: their place in
    /// the thread.
    private var nextID = 0
    private var task: Task<Void, Never>?
    /// A lookup doesn't wait for the analysis or an answer to finish, nor
    /// they for it.
    private var lookupTask: Task<Void, Never>?
    private let makeClient: () -> AnalysisClient?

    init(makeClient: @escaping () -> AnalysisClient? = { AppSettings.analysisClient }) {
        self.makeClient = makeClient
    }

    func analyze(_ caption: Caption) {
        cancel()
        captionID = caption.id
        sentence = caption.japanese
        tokenizerRuby = caption.ruby
        chinese = ""
        words = []
        followUps = []
        lookups = []
        nextID = 0
        draft = ""
        guard let client = makeClient() else {
            phase = .unconfigured
            return
        }
        phase = .running
        task = Task {
            do {
                for try await event in client.analyze(caption.japanese) {
                    switch event {
                    case .translation(let text): chinese = text
                    case .word(let word): words.append(word)
                    }
                }
                guard !Task.isCancelled else { return }
                phase = chinese.isEmpty && words.isEmpty
                    ? .failed("The LLM's answer was not in the expected format.")
                    : .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Run the same sentence again: after a failure, or a change in Settings.
    func retry() {
        guard let captionID else { return }
        analyze(Caption(id: captionID, japanese: sentence, ruby: tokenizerRuby, english: ""))
    }

    /// Ask about the sentence. The request carries the analysis as it stands
    /// and the earlier questions about this sentence with their answers.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty else { return }
        let messages = FollowUpFormat.messages(
            asking: question, after: followUps, sentence: sentence, chinese: chinese, words: words
        )
        let index = followUps.count
        followUps.append(FollowUp(id: nextID, question: question))
        nextID += 1
        guard let client = makeClient() else {
            followUps[index].error = "No LLM server is set in Settings."
            return
        }
        isAnswering = true
        task = Task {
            do {
                for try await piece in client.answer(messages) {
                    // A cancelled question may no longer be there to answer.
                    guard !Task.isCancelled else { return }
                    followUps[index].raw += piece
                }
                guard !Task.isCancelled else { return }
                if followUps[index].answer.isEmpty {
                    followUps[index].error = "The LLM gave no answer."
                }
            } catch {
                guard !Task.isCancelled else { return }
                followUps[index].error = error.localizedDescription
            }
            isAnswering = false
        }
    }

    /// Ask how text selected in the panel works grammatically in the sentence.
    /// A question like any other, so the answer is there to ask further about.
    func askAboutGrammar(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask(FollowUpFormat.grammarQuestion(about: text))
    }

    /// Ask the last question again, after it failed.
    func retryFollowUp() {
        guard !isAnswering, let last = followUps.last, last.error != nil else { return }
        followUps.removeLast()
        ask(last.question)
    }

    /// Look up text selected in the panel: a word, a conjugated form, a
    /// phrase, a term from an explanation. Its entry goes under the analysis
    /// with the questions. One at a time; the one before keeps what it has.
    func lookUp(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sentence.isEmpty else { return }
        lookupTask?.cancel()
        let id = nextID
        nextID += 1
        lookups.append(Lookup(id: id, text: text))
        guard let client = makeClient() else {
            lookups[lookups.count - 1].error = "No LLM server is set in Settings."
            lookingUp = nil
            return
        }
        lookingUp = id
        lookupTask = Task {
            do {
                for try await event in client.lookUp(text, in: sentence) {
                    guard !Task.isCancelled else { return }
                    update(id) { $0.apply(event) }
                }
                guard !Task.isCancelled else { return }
                update(id) { if $0.isEmpty { $0.error = "The LLM's answer was not in the expected format." } }
            } catch {
                guard !Task.isCancelled else { return }
                update(id) { $0.error = error.localizedDescription }
            }
            lookingUp = nil
        }
    }

    /// By id: a lookup that failed earlier may be retried, and so taken out
    /// from under this one, while this one is being written.
    private func update(_ id: Int, _ change: (inout Lookup) -> Void) {
        guard let index = lookups.firstIndex(where: { $0.id == id }) else { return }
        change(&lookups[index])
    }

    /// Look the same text up again, after it failed.
    func retryLookup(_ id: Int) {
        guard let index = lookups.firstIndex(where: { $0.id == id }), lookups[index].error != nil else { return }
        lookUp(lookups.remove(at: index).text)
    }

    /// Anything being written: the analysis, an answer, an entry.
    var isBusy: Bool {
        phase == .running || isAnswering || lookingUp != nil
    }

    /// Stops the requests, which also stops the generation on the server.
    /// What has arrived so far stays.
    func cancel() {
        task?.cancel()
        task = nil
        lookupTask?.cancel()
        lookupTask = nil
        lookingUp = nil
        isAnswering = false
        if phase == .running {
            phase = words.isEmpty && chinese.isEmpty ? .idle : .done
        }
    }
}
