import Foundation
import Observation

/// An OpenAI-compatible chat endpoint (vLLM, llama.cpp, ollama's /v1), called
/// directly from the app.
///
/// Nothing about an analysis is remembered. Each request carries the
/// instructions and the one sentence, never an earlier sentence or answer; it
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
            "messages": [
                ["role": "system", "content": AnalysisFormat.instructions],
                ["role": "user", "content": sentence],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func analyze(_ sentence: String) -> AsyncThrowingStream<AnalysisEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request(for: sentence))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines where body.count < 300 {
                            body += line
                        }
                        throw ClientError.badStatus(status, body)
                    }
                    var parser = AnalysisStreamParser()
                    for try await line in bytes.lines {
                        parser.consume(sseLine: line).forEach { continuation.yield($0) }
                    }
                    parser.finish().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The analysis showing in the side panel. There is only ever this one: the
/// next sentence replaces it, and it is never written anywhere.
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

    /// The tokenizer's readings until the breakdown is complete, then the
    /// LLM's if its words add up to the sentence.
    var ruby: [RubyToken] {
        (phase == .done ? Furigana.annotate(sentence, words: words) : nil) ?? tokenizerRuby
    }

    private var tokenizerRuby: [RubyToken] = []
    private var task: Task<Void, Never>?
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

    /// Stops the request, which also stops the generation on the server. What
    /// has arrived so far stays.
    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running {
            phase = words.isEmpty && chinese.isEmpty ? .idle : .done
        }
    }
}
