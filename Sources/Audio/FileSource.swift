import AVFoundation

/// Plays an audio file into the pipeline at real-time pace, standing in for the
/// input device, so the whole app can be
/// exercised end to end without BlackHole or a video playing:
///
///     LiveTrans.app/Contents/MacOS/LiveTrans -demoAudioPath /path/to/clip.wav -autoStart YES
final class FileSource: AudioSource {
    private let url: URL
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() throws -> AsyncStream<Data> {
        let file = try AVAudioFile(forReading: url)
        let framer = try PCMFramer(inputFormat: file.processingFormat)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)

        task = Task.detached {
            let pace = UInt64(AudioFormat.frameDuration * 1_000_000_000)
            if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
                while !Task.isCancelled, file.framePosition < file.length {
                    guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                    for frame in framer.push(buffer) {
                        continuation.yield(frame)
                        try? await Task.sleep(nanoseconds: pace)
                    }
                }
            }
            // A file just ends, where a microphone would go quiet. Feed the
            // silence the segmenter needs to close the last utterance.
            let silence = Data(count: AudioFormat.frameBytes)
            for _ in 0..<AudioFormat.frameCount(seconds: 2) where !Task.isCancelled {
                continuation.yield(silence)
                try? await Task.sleep(nanoseconds: pace)
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
