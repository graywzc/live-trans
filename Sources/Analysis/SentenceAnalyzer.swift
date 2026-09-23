import Foundation
import Observation

/// An OpenAI-compatible chat endpoint (vLLM, llama.cpp, ollama's /v1), called
/// directly from the app.
///
/// Nothing about an analysis is remembered on the server. A request carries
/// the instructions and the one sentence; for a follow-up question, what the
/// panel is showing: the sentences analyzed, and the questions about them;
/// for a lookup, the selected text and its sentence. It goes to the
/// inference server itself, not through an agent or a memory
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

/// The sentences analyzed in the side panel, one after another, with the
/// questions asked about them and the selections looked up in them in
/// between: one thread, and one conversation for the questions. It lasts
/// until it is cleared or the app quits, and is never written anywhere.
@MainActor
@Observable
final class SentenceAnalyzer {
    private(set) var analyses: [Analysis] = []
    private(set) var followUps: [FollowUp] = []
    private(set) var isAnswering = false
    private(set) var lookups: [Lookup] = []
    /// The analysis being written.
    private(set) var analyzing: Int?
    /// The lookup whose entry is being written.
    private(set) var lookingUp: Int?
    /// An item already in the thread to bring into view: a caption analyzed
    /// before, clicked again.
    private(set) var revealed: Reveal?
    /// The question being typed. Here rather than in the view, which is gone
    /// while the panel shows Jisho: looking a word up doesn't lose the question.
    var draft = ""

    struct Reveal: Equatable {
        let id: Int
        /// Tells a second request for the same item from the first.
        let serial: Int
    }

    /// A question needs an analysis to be about, and waits its turn: for the
    /// answer before it, and for a sentence being analyzed, which it may be
    /// about.
    var canAsk: Bool {
        analyzing == nil && !isAnswering && analyses.contains { $0.phase == .done }
    }

    /// Everything in the panel, in the order it was asked for.
    enum ThreadItem: Identifiable {
        case analysis(Analysis)
        case followUp(FollowUp)
        case lookup(Lookup)

        var id: Int {
            switch self {
            case .analysis(let analysis): analysis.id
            case .followUp(let followUp): followUp.id
            case .lookup(let lookup): lookup.id
            }
        }
    }

    var thread: [ThreadItem] {
        (analyses.map(ThreadItem.analysis) + followUps.map(ThreadItem.followUp) + lookups.map(ThreadItem.lookup))
            .sorted { $0.id < $1.id }
    }

    /// Analyses, questions and lookups are numbered in one sequence: their
    /// place in the thread.
    private var nextID = 0
    private var analysisTask: Task<Void, Never>?
    /// An answer doesn't stop for the next sentence: it was asked with the
    /// thread as it stood.
    private var answerTask: Task<Void, Never>?
    /// A lookup doesn't wait for the analysis or an answer to finish, nor
    /// they for it.
    private var lookupTask: Task<Void, Never>?
    private let makeClient: () -> AnalysisClient?

    init(makeClient: @escaping () -> AnalysisClient? = { AppSettings.analysisClient }) {
        self.makeClient = makeClient
    }

    /// Whether the caption's sentence is in the thread.
    func hasAnalyzed(_ caption: Caption) -> Bool {
        analyses.contains { $0.captionID == caption.id }
    }

    /// Adds the caption's sentence to the thread, or, if it is there already,
    /// brings it into view, running it again if it didn't get anywhere.
    func analyze(_ caption: Caption) {
        if let existing = analyses.first(where: { $0.captionID == caption.id }) {
            switch existing.phase {
            case .failed, .unconfigured: run(existing.id)
            case .running, .done: break
            }
            revealed = Reveal(id: existing.id, serial: (revealed?.serial ?? 0) + 1)
            return
        }
        let id = nextID
        nextID += 1
        analyses.append(Analysis(id: id, captionID: caption.id, sentence: caption.japanese, tokenizerRuby: caption.ruby))
        run(id)
    }

    /// Run a sentence again: after a failure, or a change in Settings.
    func retry(_ id: Int) {
        guard analyses.contains(where: { $0.id == id }) else { return }
        run(id)
    }

    /// One analysis at a time; the next one stops the one before.
    private func run(_ id: Int) {
        stopAnalysis()
        guard let client = makeClient() else {
            update(id) { $0.phase = .unconfigured }
            return
        }
        guard let sentence = analyses.first(where: { $0.id == id })?.sentence else { return }
        update(id) {
            $0.chinese = ""
            $0.words = []
            $0.phase = .running
        }
        analyzing = id
        analysisTask = Task {
            do {
                for try await event in client.analyze(sentence) {
                    guard !Task.isCancelled else { return }
                    update(id) {
                        switch event {
                        case .translation(let text): $0.chinese = text
                        case .word(let word): $0.words.append(word)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                update(id) {
                    $0.phase = $0.isEmpty ? .failed("The LLM's answer was not in the expected format.") : .done
                }
            } catch {
                guard !Task.isCancelled else { return }
                update(id) { $0.phase = .failed(error.localizedDescription) }
            }
            analyzing = nil
        }
    }

    /// What has arrived of it stays; an analysis that had nothing yet goes.
    private func stopAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        guard let id = analyzing else { return }
        analyzing = nil
        if analyses.first(where: { $0.id == id })?.isEmpty == true {
            analyses.removeAll { $0.id == id }
        } else {
            update(id) { $0.phase = .done }
        }
    }

    private func update(_ id: Int, _ change: (inout Analysis) -> Void) {
        guard let index = analyses.firstIndex(where: { $0.id == id }) else { return }
        change(&analyses[index])
    }

    /// Ask about the sentences. The request carries the thread as it stands:
    /// every analysis, and the earlier questions with their answers.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty else { return }
        let messages = FollowUpFormat.messages(asking: question, after: thread)
        let index = followUps.count
        followUps.append(FollowUp(id: nextID, question: question))
        nextID += 1
        guard let client = makeClient() else {
            followUps[index].error = "No LLM server is set in Settings."
            return
        }
        isAnswering = true
        answerTask = Task {
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

    /// Ask how text selected in the panel works grammatically in the sentence
    /// it is under (see `lookUp`). A question like any other, so the answer
    /// is there to ask further about.
    func askAboutGrammar(_ text: String, under itemID: Int? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sentence = sentence(under: itemID) else { return }
        ask(FollowUpFormat.grammarQuestion(about: text, in: sentence))
    }

    /// Ask the last question again, after it failed.
    func retryFollowUp() {
        guard !isAnswering, let last = followUps.last, last.error != nil else { return }
        followUps.removeLast()
        ask(last.question)
    }

    /// Look up text selected in the panel: a word, a conjugated form, a
    /// phrase, a term from an explanation. The sentence that goes with it is
    /// the one the selection was in, or was under: that of the analysis at or
    /// before `itemID`, the newest without one. Its entry goes at the end of
    /// the thread. One at a time; the one before keeps what it has.
    func lookUp(_ text: String, under itemID: Int? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sentence = sentence(under: itemID) else { return }
        lookUp(text, in: sentence)
    }

    /// That of the analysis at or before the item, the newest without one.
    private func sentence(under itemID: Int?) -> String? {
        (analyses.last { $0.id <= itemID ?? .max } ?? analyses.first)?.sentence
    }

    private func lookUp(_ text: String, in sentence: String) {
        lookupTask?.cancel()
        let id = nextID
        nextID += 1
        lookups.append(Lookup(id: id, text: text, sentence: sentence))
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
                    updateLookup(id) { $0.apply(event) }
                }
                guard !Task.isCancelled else { return }
                updateLookup(id) { if $0.isEmpty { $0.error = "The LLM's answer was not in the expected format." } }
            } catch {
                guard !Task.isCancelled else { return }
                updateLookup(id) { $0.error = error.localizedDescription }
            }
            lookingUp = nil
        }
    }

    /// By id: a lookup that failed earlier may be retried, and so taken out
    /// from under this one, while this one is being written.
    private func updateLookup(_ id: Int, _ change: (inout Lookup) -> Void) {
        guard let index = lookups.firstIndex(where: { $0.id == id }) else { return }
        change(&lookups[index])
    }

    /// Look the same text up again, after it failed.
    func retryLookup(_ id: Int) {
        guard let index = lookups.firstIndex(where: { $0.id == id }), lookups[index].error != nil else { return }
        let lookup = lookups.remove(at: index)
        lookUp(lookup.text, in: lookup.sentence)
    }

    /// Anything being written: an analysis, an answer, an entry.
    var isBusy: Bool {
        analyzing != nil || isAnswering || lookingUp != nil
    }

    /// Stops the requests, which also stops the generation on the server.
    /// What has arrived so far stays.
    func cancel() {
        stopAnalysis()
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
        lookupTask?.cancel()
        lookupTask = nil
        lookingUp = nil
    }

    /// Starts over: the questions that come next go without the sentences so
    /// far, which also keeps the requests from growing without end.
    func clear() {
        cancel()
        analyses = []
        followUps = []
        lookups = []
        revealed = nil
        nextID = 0
    }
}
