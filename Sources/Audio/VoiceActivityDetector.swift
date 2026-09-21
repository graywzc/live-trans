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
    /// Inside an utterance the bar drops to this fraction of `speechRatio`
    /// (about -4 dB). A sentence is not evenly loud: what has to stand out to
    /// open an utterance is its loudest syllable, and the soft words and the
    /// trailing particle after it should not read as the speaker stopping.
    var continuationFactor: Float = 0.6
    /// However sensitive the setting, continuing still takes a frame clearly
    /// above the floor, or the background alone would hold an utterance open.
    var minimumContinuationRatio: Float = 1.5
    /// How long an unbroken run of speech frames may hold the floor still.
    /// Talking pauses for breath well within this; a fan never does.
    var floorHold: TimeInterval = 5.0

    private(set) var noiseFloor: Float?
    private(set) var lastRMS: Float = 0
    private var speechRun = 0

    /// What a frame must exceed to open an utterance.
    var threshold: Float {
        max(minimumThreshold, (noiseFloor ?? 0) * speechRatio)
    }

    /// What a frame must exceed to count as speech once an utterance is open.
    var continuationThreshold: Float {
        let ratio = min(speechRatio, max(minimumContinuationRatio, speechRatio * continuationFactor))
        return max(minimumThreshold, (noiseFloor ?? 0) * ratio)
    }

    mutating func isSpeech(_ frame: Data, inUtterance: Bool = false) -> Bool {
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
            // quickly on the way down.
            noiseFloor = floor + (rms - floor) * 0.2
        }
        let isSpeech = rms > (inUtterance ? continuationThreshold : threshold)
        speechRun = isSpeech ? speechRun + 1 : 0

        // On the way up, creep slowly (doubling takes ~10 s), so a fan
        // switching on eventually becomes the floor. Not while someone is
        // talking, though: a monologue over a music bed never dips below the
        // floor, and would otherwise raise the bar on its own next sentence
        // by 6% a second.
        let held = speechRun > 0 && speechRun <= AudioFormat.frameCount(seconds: floorHold)
        if rms >= floor, !held {
            noiseFloor = max(floor, 1) * 1.002
        }
        return isSpeech
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
