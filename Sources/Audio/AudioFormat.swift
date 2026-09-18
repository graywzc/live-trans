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
