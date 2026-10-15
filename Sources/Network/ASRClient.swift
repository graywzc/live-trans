import Foundation

struct ServerHealth: Decodable, Equatable {
    var status: String?
    var asr: String?
    var device: String?
    var translationBackend: String?
    var ollamaModel: String?
    /// The server can fetch a video's audio ahead and caption it.
    var prefetch: Bool?

    enum CodingKeys: String, CodingKey {
        case status, asr, device, prefetch
        case translationBackend = "translation_backend"
        case ollamaModel = "ollama_model"
    }
}

/// How far a pre-fetch has got, and its lines from `since` on.
struct PrefetchStatus: Decodable, Equatable {
    var state: String
    var error: String?
    var duration: Double?
    /// Where in the video the job began. A server that can only begin at
    /// the top doesn't say.
    var start: Double?
    var fetched: Double
    var ready: Double
    var count: Int
    var lines: [CaptionPair]
    /// The step a dev job runs on its own, and up to where in the video
    /// it has looked.
    var step: String?
    var analysed: Double?
    /// Whether a dev job's audio came from the host's cache of it.
    var cached: Bool?
}

/// What a dev job's step has found so far.
struct StepFindings: Decodable, Equatable {
    var step: String?
    var analysed: Double
    /// Where the speech is, as [start, end] pairs in seconds of the video.
    var speech: [[Double]]
    /// FireRedVAD's step only: where it hears singing, and music with
    /// neither singing nor speech, by kind ("singing", "music"), as pairs.
    var events: [String: [[Double]]]?

    var stretches: [ClosedRange<Double>] { Self.ranges(speech) }

    var soundEvents: DevPipeline.SoundEvents {
        DevPipeline.SoundEvents(singing: Self.ranges(events?["singing"] ?? []), music: Self.ranges(events?["music"] ?? []))
    }

    private static func ranges(_ pairs: [[Double]]) -> [ClosedRange<Double>] {
        pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }
}

struct CaptionPair: Decodable, Equatable {
    var ja: String
    var en: String
    /// Where the sentence starts and ends in the audio sent, in seconds,
    /// when the server could place its words.
    var start: Double?
    var end: Double?
}

struct Transcription: Equatable {
    var japanese: String
    /// One sentence per pair.
    var lines: [CaptionPair]
}

/// Client for server/asr_server.py.
struct ASRClient {
    enum ClientError: LocalizedError {
        case server(String)
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .server(let message): "GPU server error: \(message)"
            case .badStatus(let code): "GPU server returned HTTP \(code)"
            }
        }
    }

    let baseURL: URL
    /// Ephemeral: the shared session writes every response to a cache on
    /// disk, captions included.
    var session = URLSession(configuration: .ephemeral)

    func health(timeout: TimeInterval = 5) async -> ServerHealth? {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = timeout
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }
        return try? JSONDecoder().decode(ServerHealth.self, from: data)
    }

    /// Send PCM s16le mono 16 kHz upstream. Throws on transport failure so the
    /// caller can retry. `prompt` is text said just before, which Whisper
    /// reads before listening.
    func transcribe(pcm: Data, beamSize: Int, translate: Bool, prompt: String? = nil) async throws -> Transcription {
        let request = Self.transcribeRequest(
            baseURL: baseURL, beamSize: beamSize, translate: translate, prompt: prompt
        )
        let (data, response) = try await session.upload(for: request, from: pcm)
        return try Self.decodeTranscription(
            data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }

    /// Start fetching a video's audio from `start` seconds in, ahead of the
    /// viewer. Returns the job. With `step`, the job runs that step of the
    /// pipeline alone over the whole of the audio, making no captions.
    func startPrefetch(
        url: String?, page: String, headers: [String: String], duration: Double?, start: Double = 0,
        step: String? = nil
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "prefetch"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["url": url ?? "", "page": page, "headers": headers, "start": start]
        if let duration { body["duration"] = duration }
        if let step { body["step"] = step }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        struct Payload: Decodable { var job: String?; var error: String? }
        let payload = try Self.decode(Payload.self, from: data, statusCode: response)
        guard let job = payload.job else { throw ClientError.server(payload.error ?? "no job") }
        return job
    }

    func prefetchStatus(job: String, since: Int) async throws -> PrefetchStatus {
        var components = URLComponents(url: baseURL.appending(path: "prefetch/\(job)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return try Self.decode(PrefetchStatus.self, from: data, statusCode: response)
    }

    /// The stretch heard again from the fetched audio. With `speechOnly`
    /// the host's voice filter picks the speech out of it first, and music
    /// or silence gives nothing rather than invented lines.
    func rehear(job: String, from start: Double, to end: Double, speechOnly: Bool = false) async throws -> [CaptionPair] {
        var components = URLComponents(url: baseURL.appending(path: "prefetch/\(job)/rehear"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: String(start)), URLQueryItem(name: "to", value: String(end)),
        ]
        if speechOnly {
            components.queryItems?.append(URLQueryItem(name: "vad", value: "1"))
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        struct Payload: Decodable { var lines: [CaptionPair] }
        return try Self.decode(Payload.self, from: data, statusCode: response).lines
    }

    /// What a dev job's step has found so far.
    func stepFindings(job: String) async throws -> StepFindings {
        var request = URLRequest(url: baseURL.appending(path: "prefetch/\(job)/speech"))
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return try Self.decode(StepFindings.self, from: data, statusCode: response)
    }

    /// The job's fetched audio from `start` to `end` of the video, as a WAV
    /// file; the server gives at most a couple of minutes at once.
    func prefetchAudio(job: String, from start: Double, to end: Double) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: "prefetch/\(job)/audio"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: String(start)), URLQueryItem(name: "to", value: String(end)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let message = (try? JSONDecoder().decode(ServerFailure.self, from: data))?.error {
                throw ClientError.server(message)
            }
            throw ClientError.badStatus(code)
        }
        return data
    }

    /// Empties the host's cache of videos fetched and findings made in dev
    /// mode; how many videos it held.
    func clearDevCache() async throws -> Int {
        var request = URLRequest(url: baseURL.appending(path: "devcache/clear"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        struct Payload: Decodable { var cleared: Int }
        return try Self.decode(Payload.self, from: data, statusCode: response).cleared
    }

    func stopPrefetch(job: String) async {
        var request = URLRequest(url: baseURL.appending(path: "prefetch/\(job)/stop"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    /// Holds the job's transcription, or lets it go on; the audio keeps
    /// being fetched either way.
    func setPrefetch(job: String, paused: Bool) async throws {
        var request = URLRequest(url: baseURL.appending(path: "prefetch/\(job)/\(paused ? "pause" : "resume")"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        struct Payload: Decodable { var state: String? }
        _ = try Self.decode(Payload.self, from: data, statusCode: response)
    }

    /// The server's log from line `since` on. A server from before it kept
    /// one answers 404, which throws.
    func events(since: Int) async throws -> HostEvents {
        var components = URLComponents(url: baseURL.appending(path: "events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        return try Self.decode(HostEvents.self, from: data, statusCode: response)
    }

    private struct ServerFailure: Decodable { var error: String? }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, statusCode response: URLResponse) throws -> T {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            if let message = (try? JSONDecoder().decode(ServerFailure.self, from: data))?.error {
                throw ClientError.server(message)
            }
            throw ClientError.badStatus(code)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.badStatus(code)
        }
    }

    /// Ask the server to exit and release the GPU now rather than waiting out
    /// its idle timeout.
    func shutdown() async {
        var request = URLRequest(url: baseURL.appending(path: "shutdown"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    static func transcribeRequest(baseURL: URL, beamSize: Int, translate: Bool, prompt: String?) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "transcribe"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "beam_size", value: String(beamSize)),
            URLQueryItem(name: "translate", value: translate ? "1" : "0"),
        ]
        if let prompt, !prompt.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "prompt", value: prompt))
            // Foundation leaves "+" as is, which a query parser reads as a
            // space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func decodeTranscription(_ data: Data, statusCode: Int) throws -> Transcription {
        struct Payload: Decodable {
            var ja: String?
            var en: String?
            var lines: [CaptionPair]?
            var error: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ClientError.badStatus(statusCode)
        }
        if let error = payload.error {
            throw ClientError.server(error)
        }
        guard statusCode == 200 else {
            throw ClientError.badStatus(statusCode)
        }
        let japanese = payload.ja ?? ""
        // A server predating sentence splitting sends one pair for the segment.
        let lines = payload.lines
            ?? (japanese.isEmpty ? [] : [CaptionPair(ja: japanese, en: payload.en ?? "")])
        return Transcription(japanese: japanese, lines: lines)
    }
}
