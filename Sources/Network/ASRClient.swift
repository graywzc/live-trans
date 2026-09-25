import Foundation

struct ServerHealth: Decodable, Equatable {
    var status: String?
    var asr: String?
    var device: String?
    var translationBackend: String?
    var ollamaModel: String?

    enum CodingKeys: String, CodingKey {
        case status, asr, device
        case translationBackend = "translation_backend"
        case ollamaModel = "ollama_model"
    }
}

struct CaptionPair: Decodable, Equatable {
    var ja: String
    var en: String
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
    var session: URLSession = .shared

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
