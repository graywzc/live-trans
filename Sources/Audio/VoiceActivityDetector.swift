import Foundation

/// Energy VAD with an adaptive noise floor.
///
/// A fixed RMS threshold is enough for BlackHole, which delivers digital
/// silence between lines. It breaks as soon as the input is a real microphone,
/// or the video has a music bed: the noise floor differs per source and
/// drifts, so speech is judged relative to a running estimate of it.
struct VoiceActivityDetector {
    /// How many times louder than the noise floor a frame must be.
    var speechRatio: Float = 3.0
    /// Never treat anything quieter than this as speech, however silent the
    /// room is; otherwise the faintest rustle clears a near-zero floor.
    var minimumThreshold: Float = 60

    private(set) var noiseFloor: Float?
    private(set) var lastRMS: Float = 0

    var threshold: Float {
        max(minimumThreshold, (noiseFloor ?? 0) * speechRatio)
    }

    mutating func isSpeech(_ frame: Data) -> Bool {
        let rms = Self.rms(frame)
        lastRMS = rms

        guard let floor = noiseFloor else {
            // Nothing to compare against yet, so this frame only seeds the
            // estimate. If someone is already talking the floor starts high,
            // and falls to the real one at the first gap between words.
            noiseFloor = rms
            return false
        }
        if rms < floor {
            // The gaps between words drop to the true floor, so follow
            // quickly on the way down ...
            noiseFloor = floor + (rms - floor) * 0.2
        } else {
            // ... and creep up slowly (doubling takes ~10 s), so speech itself
            // doesn't raise the bar but a fan switching on eventually does.
            noiseFloor = max(floor, 1) * 1.002
        }
        return rms > threshold
    }

    /// RMS on the int16 scale (0...32768).
    static func rms(_ frame: Data) -> Float {
        let count = frame.count / AudioFormat.bytesPerSample
        guard count > 0 else { return 0 }
        let sumOfSquares: Float = frame.withUnsafeBytes { raw in
            var sum: Float = 0
            for index in 0..<count {
                let sample = Float(raw.loadUnaligned(
                    fromByteOffset: index * AudioFormat.bytesPerSample, as: Int16.self
                ))
                sum += sample * sample
            }
            return sum
        }
        return (sumOfSquares / Float(count)).squareRoot()
    }
}
