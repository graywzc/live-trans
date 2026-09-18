import Foundation

/// The wire format asr_server.py expects: PCM s16le mono 16 kHz, handled in
/// 30 ms frames.
enum AudioFormat {
    static let sampleRate = 16_000
    static let frameDuration: TimeInterval = 0.03
    static let frameSamples = 480
    static let bytesPerSample = 2
    static let frameBytes = frameSamples * bytesPerSample

    static func frameCount(seconds: TimeInterval) -> Int {
        Int((seconds / frameDuration).rounded())
    }
}

/// Where caption audio comes from. Frames are `AudioFormat.frameBytes` long.
protocol AudioSource: AnyObject {
    func start() throws -> AsyncStream<Data>
    func stop()
}

/// Cuts a byte stream of PCM into fixed 30 ms frames.
struct FrameChunker {
    private var residual = Data()

    mutating func push(_ pcm: Data) -> [Data] {
        residual.append(pcm)
        var frames: [Data] = []
        while residual.count >= AudioFormat.frameBytes {
            // Data is its own slice type and keeps the parent's indices; copy
            // so every frame and the remainder are zero-based.
            frames.append(Data(residual.prefix(AudioFormat.frameBytes)))
            residual = Data(residual.dropFirst(AudioFormat.frameBytes))
        }
        return frames
    }
}
