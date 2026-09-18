import AVFoundation

/// Resamples whatever the hardware (or a file) delivers to the server's wire
/// format and cuts it into fixed 30 ms frames.
final class PCMFramer {
    enum FramerError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? {
            "Audio input format is not supported."
        }
    }

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var residual = Data()

    init(inputFormat: AVAudioFormat) throws {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(AudioFormat.sampleRate),
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw FramerError.unsupportedFormat
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func push(_ buffer: AVAudioPCMBuffer) -> [Data] {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        // One converter for the whole stream, fed a buffer at a time: it keeps
        // the resampler's filter state across calls, so there is no click at
        // each buffer boundary.
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else {
            return []
        }
        residual.append(UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength)))

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
