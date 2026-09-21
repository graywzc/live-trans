import XCTest
@testable import LiveTrans

final class UtteranceSegmenterTests: XCTestCase {
    private var segmenter = UtteranceSegmenter()

    override func setUp() {
        segmenter = UtteranceSegmenter()
    }

    /// Frames are tagged with a marker byte so tests can tell which made it
    /// into an utterance.
    private func frame(_ marker: UInt8 = 0) -> Data {
        Data(repeating: marker, count: AudioFormat.frameBytes)
    }

    @discardableResult
    private func feed(seconds: TimeInterval, speech: Bool, marker: UInt8 = 0) -> [UtteranceSegmenter.Event] {
        (0..<AudioFormat.frameCount(seconds: seconds)).flatMap { _ in
            segmenter.process(frame: frame(marker), isSpeech: speech)
        }
    }

    private func seconds(of audio: Data) -> TimeInterval {
        Double(frames(in: audio)) * AudioFormat.frameDuration
    }

    /// Durations are asserted in whole frames where it matters: a second is not
    /// a whole number of 30 ms frames, and an off-by-one frame is the bug these
    /// tests exist to catch, so a tolerance in seconds would hide it.
    private func frames(in audio: Data) -> Int {
        audio.count / AudioFormat.frameBytes
    }

    private func frames(_ seconds: TimeInterval) -> Int {
        AudioFormat.frameCount(seconds: seconds)
    }

    func testSilenceProducesNothing() {
        XCTAssertEqual(feed(seconds: 5, speech: false), [])
    }

    func testSpeechThenPauseProducesFinalWithPreAndPostRoll() throws {
        feed(seconds: 2, speech: false, marker: 1)
        let speaking = feed(seconds: 1, speech: true, marker: 2)
        XCTAssertEqual(speaking, [.started(utterance: 0)])

        let events = feed(seconds: 1, speech: false, marker: 3)
        guard case .final(let audio, let utterance)? = events.last else {
            return XCTFail("expected a final, got \(events)")
        }
        XCTAssertEqual(utterance, 0)
        // Pre-roll + the speech + post-roll, not the whole 1 s silence timeout.
        XCTAssertEqual(frames(in: audio), frames(0.3) + frames(1) + frames(0.3))
        XCTAssertEqual(audio.first, 1)
        XCTAssertEqual(audio.last, 3)
    }

    func testShortNoiseIsDiscarded() {
        feed(seconds: 0.09, speech: true)
        let events = feed(seconds: 1, speech: false)
        XCTAssertEqual(events, [.discarded(utterance: 0)])
    }

    /// Over a music bed only the peaks of a sentence clear the VAD threshold.
    /// That is still a sentence, however few frames were flagged.
    func testSparseSpeechFramesAreNotMistakenForNoise() {
        var events: [UtteranceSegmenter.Event] = []
        for _ in 0..<4 {
            events += feed(seconds: 0.03, speech: true)
            events += feed(seconds: 0.27, speech: false)
        }
        events += feed(seconds: 1, speech: false)
        guard case .final? = events.last else {
            return XCTFail("expected a final, got \(String(describing: events.last))")
        }
    }

    /// A partial puts text on screen. An utterance that ends up discarded must
    /// never have shown any, or the text vanishes with nothing to replace it.
    func testNoPartialForAnUtteranceThatIsDiscarded() {
        // Long enough to reach the first partial, during the trailing silence.
        feed(seconds: 2, speech: false)
        var events = feed(seconds: 0.24, speech: true)
        events += feed(seconds: 1, speech: false)
        XCTAssertEqual(events, [.started(utterance: 0), .discarded(utterance: 0)])
    }

    func testUtteranceNumbersAdvance() {
        feed(seconds: 0.09, speech: true)
        feed(seconds: 1, speech: false)
        let events = feed(seconds: 1, speech: true)
        XCTAssertEqual(events, [.started(utterance: 1)])
    }

    func testPartialsDuringLongSpeechAndForcedFinal() {
        let events = feed(seconds: 12, speech: true)

        let partials = events.compactMap { event -> Data? in
            if case .partial(let audio, _) = event { return audio }
            return nil
        }
        // First at 1.5 s, then every 2 s: 1.5, 3.5, 5.5, 7.5, 9.5, 11.5.
        XCTAssertEqual(partials.count, 6)
        XCTAssertEqual(seconds(of: partials[0]), 1.5, accuracy: 0.001)
        // Partials never exceed the rolling window.
        XCTAssertEqual(seconds(of: partials[5]), 6.0, accuracy: 0.001)

        guard case .final(let audio, _)? = events.last else {
            return XCTFail("expected a forced final, got \(String(describing: events.last))")
        }
        XCTAssertEqual(seconds(of: audio), 12.0, accuracy: 0.001)
    }

    func testBriefPauseDoesNotSplitUtterance() {
        feed(seconds: 1, speech: true)
        let pause = feed(seconds: 0.5, speech: false)
        XCTAssertFalse(pause.contains { if case .final = $0 { true } else { false } })
        feed(seconds: 1, speech: true)
        let events = feed(seconds: 1, speech: false)
        guard case .final(let audio, _)? = events.last else {
            return XCTFail("expected a final")
        }
        // Both stretches of speech and the pause between them, plus post-roll.
        // No pre-roll: nothing preceded the first word.
        XCTAssertEqual(frames(in: audio), frames(1) + frames(0.5) + frames(1) + frames(0.3))
    }
}
