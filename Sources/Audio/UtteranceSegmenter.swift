import Foundation

/// Cuts the frame stream into utterances: a rolling partial every couple of
/// seconds while someone is talking, and a final once they pause or have gone
/// on too long.
///
/// Time is counted in frames rather than read from the wall clock. Audio
/// arrives in bursts (one tap callback holds several frames), and frame time is
/// what the audio itself says happened; it also makes this testable.
struct UtteranceSegmenter {
    struct Config {
        var partialWindow: TimeInterval = 6.0
        var partialInterval: TimeInterval = 2.0
        var minPartialAudio: TimeInterval = 1.5
        var silenceTimeout: TimeInterval = 1.0
        var maxUtterance: TimeInterval = 12.0
        /// Audio kept from before the first speech frame, so the onset of the
        /// first word isn't clipped.
        var preRoll: TimeInterval = 0.3
        /// Silence kept after the last speech frame. The full silence timeout
        /// is not sent: Whisper tends to hallucinate over trailing silence.
        var postRoll: TimeInterval = 0.3
        /// Utterances with less speech than this are dropped. A door slam or a
        /// cough is a few frames; transcribing it yields an invented sentence.
        var minSpeech: TimeInterval = 0.3
    }

    enum Event: Equatable {
        case started(utterance: Int)
        case partial(audio: Data, utterance: Int)
        case final(audio: Data, utterance: Int)
        case discarded(utterance: Int)
    }

    let config: Config

    private var preRollFrames: [Data] = []
    private var utteranceFrames: [Data] = []
    private var isActive = false
    private var utteranceID = 0
    private var speechFrames = 0
    private var lastSpeechIndex = 0
    private var framesSincePartial = 0

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func process(frame: Data, isSpeech: Bool) -> [Event] {
        guard isActive else {
            guard isSpeech else {
                preRollFrames.append(frame)
                let limit = AudioFormat.frameCount(seconds: config.preRoll)
                if preRollFrames.count > limit {
                    preRollFrames.removeFirst(preRollFrames.count - limit)
                }
                return []
            }
            isActive = true
            utteranceFrames = preRollFrames + [frame]
            preRollFrames = []
            speechFrames = 1
            lastSpeechIndex = utteranceFrames.count - 1
            // Due immediately, so the first partial appears as soon as there
            // is enough audio to be worth transcribing.
            framesSincePartial = AudioFormat.frameCount(seconds: config.partialInterval)
            return [.started(utterance: utteranceID)]
        }

        utteranceFrames.append(frame)
        framesSincePartial += 1
        if isSpeech {
            speechFrames += 1
            lastSpeechIndex = utteranceFrames.count - 1
        }

        let silentFrames = utteranceFrames.count - 1 - lastSpeechIndex
        let paused = silentFrames >= AudioFormat.frameCount(seconds: config.silenceTimeout)
        let tooLong = utteranceFrames.count >= AudioFormat.frameCount(seconds: config.maxUtterance)
        if paused || tooLong {
            return [finish()]
        }

        if utteranceFrames.count >= AudioFormat.frameCount(seconds: config.minPartialAudio),
           framesSincePartial >= AudioFormat.frameCount(seconds: config.partialInterval) {
            framesSincePartial = 0
            let window = utteranceFrames.suffix(AudioFormat.frameCount(seconds: config.partialWindow))
            return [.partial(audio: Self.join(window), utterance: utteranceID)]
        }
        return []
    }

    private mutating func finish() -> Event {
        defer {
            utteranceID += 1
            isActive = false
            utteranceFrames = []
        }
        guard speechFrames >= AudioFormat.frameCount(seconds: config.minSpeech) else {
            return .discarded(utterance: utteranceID)
        }
        let end = min(
            utteranceFrames.count,
            lastSpeechIndex + 1 + AudioFormat.frameCount(seconds: config.postRoll)
        )
        return .final(audio: Self.join(utteranceFrames[..<end]), utterance: utteranceID)
    }

    private static func join<Frames: Collection>(_ frames: Frames) -> Data where Frames.Element == Data {
        var audio = Data(capacity: frames.count * AudioFormat.frameBytes)
        for frame in frames {
            audio.append(frame)
        }
        return audio
    }
}
