import XCTest
@testable import LiveTrans

final class VoiceActivityDetectorTests: XCTestCase {
    private func frame(amplitude: Int16) -> Data {
        // A square wave: its RMS is exactly the amplitude.
        var data = Data(capacity: AudioFormat.frameBytes)
        for index in 0..<AudioFormat.frameSamples {
            var sample = index % 2 == 0 ? amplitude : -amplitude
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testRMS() {
        XCTAssertEqual(VoiceActivityDetector.rms(frame(amplitude: 1000)), 1000, accuracy: 0.5)
        XCTAssertEqual(VoiceActivityDetector.rms(Data()), 0)
    }

    func testSpeechStandsOutFromRoomNoise() {
        var vad = VoiceActivityDetector()
        for _ in 0..<100 {
            XCTAssertFalse(vad.isSpeech(frame(amplitude: 150)))
        }
        XCTAssertTrue(vad.isSpeech(frame(amplitude: 1500)))
        // Noise a little above the floor is still noise.
        XCTAssertFalse(vad.isSpeech(frame(amplitude: 250)))
    }

    func testQuietRoomStillNeedsMinimumLevel() {
        var vad = VoiceActivityDetector()
        for _ in 0..<100 {
            _ = vad.isSpeech(frame(amplitude: 2))
        }
        XCTAssertFalse(vad.isSpeech(frame(amplitude: 30)))
    }

    func testFloorAdaptsWhenNoiseRises() {
        var vad = VoiceActivityDetector()
        for _ in 0..<100 {
            _ = vad.isSpeech(frame(amplitude: 100))
        }
        // A fan switches on: loud enough to trip the VAD at first ...
        XCTAssertTrue(vad.isSpeech(frame(amplitude: 400)))
        // ... but after a minute it has become the new floor.
        for _ in 0..<AudioFormat.frameCount(seconds: 60) {
            _ = vad.isSpeech(frame(amplitude: 400))
        }
        XCTAssertFalse(vad.isSpeech(frame(amplitude: 400)))
    }

    /// The soft end of a sentence is too quiet to open an utterance, but must
    /// not read as the speaker having stopped.
    func testQuieterSpeechCountsOnceAnUtteranceIsOpen() {
        var vad = VoiceActivityDetector()
        for _ in 0..<100 {
            _ = vad.isSpeech(frame(amplitude: 100))
        }
        XCTAssertFalse(vad.isSpeech(frame(amplitude: 250)))
        XCTAssertTrue(vad.isSpeech(frame(amplitude: 250), inUtterance: true))
        // The background itself never does, however sensitive the setting.
        vad.speechRatio = 1.8
        XCTAssertFalse(vad.isSpeech(frame(amplitude: 120), inUtterance: true))
    }

    /// Over a music bed nothing dips below the floor, so a floor that rose
    /// through a sentence would make the next one harder to hear.
    func testTalkingDoesNotRaiseTheFloor() {
        var vad = VoiceActivityDetector()
        for _ in 0..<100 {
            _ = vad.isSpeech(frame(amplitude: 100))
        }
        let before = vad.threshold
        for _ in 0..<AudioFormat.frameCount(seconds: 4) {
            XCTAssertTrue(vad.isSpeech(frame(amplitude: 1500), inUtterance: true))
        }
        XCTAssertEqual(vad.threshold, before)
    }
}

final class FuriganaTests: XCTestCase {
    func testReadingGoesOverKanjiOnly() {
        let tokens = Furigana.annotate("食べる")
        XCTAssertEqual(tokens, [
            RubyToken(base: "食", reading: "た"),
            RubyToken(base: "べる", continuesWord: true),
        ])
    }

    func testKanaHasNoReading() {
        XCTAssertTrue(Furigana.annotate("ありがとう テレビ").allSatisfy { $0.reading == nil })
    }

    func testTextIsPreservedIncludingPunctuation() {
        let text = "お兄ちゃん、学校に遅れるよ! OK?"
        let tokens = Furigana.annotate(text)
        XCTAssertEqual(tokens.map(\.base).joined(), text)
        XCTAssertTrue(tokens.contains(RubyToken(base: "、", gluesToPrevious: true)))
        XCTAssertTrue(tokens.contains(RubyToken(base: "学校", reading: "がっこう")))
    }

    func testEmptyText() {
        XCTAssertEqual(Furigana.annotate(""), [])
    }
}

final class ASRClientTests: XCTestCase {
    func testDecodesSentenceLines() throws {
        let json = #"{"ja":"こんにちは元気","en":"Hello. How are you?","lines":[{"ja":"こんにちは","en":"Hello."},{"ja":"元気","en":"How are you?"}],"rtf":0.05}"#
        let result = try ASRClient.decodeTranscription(Data(json.utf8), statusCode: 200)
        XCTAssertEqual(result.japanese, "こんにちは元気")
        XCTAssertEqual(result.lines, [
            CaptionPair(ja: "こんにちは", en: "Hello."),
            CaptionPair(ja: "元気", en: "How are you?"),
        ])
    }

    func testDecodesServerWithoutSentenceSplitting() throws {
        let json = #"{"ja":"こんにちは","en":"Hello."}"#
        let result = try ASRClient.decodeTranscription(Data(json.utf8), statusCode: 200)
        XCTAssertEqual(result.lines, [CaptionPair(ja: "こんにちは", en: "Hello.")])
    }

    func testPartialResponseHasNoTranslation() throws {
        let json = #"{"ja":"こんにちは","en":"","lines":[{"ja":"こんにちは","en":""}]}"#
        let result = try ASRClient.decodeTranscription(Data(json.utf8), statusCode: 200)
        XCTAssertEqual(result.japanese, "こんにちは")
    }

    func testServerErrorThrows() {
        let json = #"{"error":"RuntimeError: CUDA out of memory"}"#
        XCTAssertThrowsError(try ASRClient.decodeTranscription(Data(json.utf8), statusCode: 500)) { error in
            XCTAssertTrue(error.localizedDescription.contains("CUDA out of memory"))
        }
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ASRClient.decodeTranscription(Data("<html>".utf8), statusCode: 502))
    }
}

final class ServerConfigTests: XCTestCase {
    func testLaunchCommandDetachesServer() {
        let config = ServerConfig(
            sshHost: "gpubox", port: 8770, remoteDir: "~/livetrans",
            remotePython: "~/venvs/livetrans/bin/python", idleTimeout: 180
        )
        XCTAssertEqual(
            config.launchCommand,
            "cd ~/livetrans && setsid nohup ~/venvs/livetrans/bin/python asr_server.py "
                + "--host 0.0.0.0 --port 8770 --idle-timeout 180 "
                + "< /dev/null >> ~/livetrans/server.log 2>&1 & disown; echo started"
        )
    }
}

final class FrameChunkerTests: XCTestCase {
    func testCutsArbitraryChunksIntoWholeFrames() {
        var chunker = FrameChunker()
        // Capture buffers arrive in sizes unrelated to the frame size.
        let stream = Data((0..<2500).map { UInt8($0 % 251) })
        var frames: [Data] = []
        for start in stride(from: 0, to: stream.count, by: 341) {
            frames += chunker.push(stream.subdata(in: start..<min(start + 341, stream.count)))
        }
        XCTAssertEqual(frames.count, 2500 / AudioFormat.frameBytes)
        XCTAssertTrue(frames.allSatisfy { $0.count == AudioFormat.frameBytes && $0.startIndex == 0 })
        // Nothing dropped, duplicated or reordered.
        XCTAssertEqual(frames.reduce(Data(), +), stream.prefix(frames.count * AudioFormat.frameBytes))
    }
}

final class OutputRouterTests: XCTestCase {
    private let aggregates = [
        OutputRouter.Aggregate(uid: "multi-speaker", subDeviceUIDs: ["speaker", "blackhole"]),
        OutputRouter.Aggregate(uid: "multi-airpods-a", subDeviceUIDs: ["airpods-a", "blackhole"]),
        OutputRouter.Aggregate(uid: "multi-airpods-b", subDeviceUIDs: ["airpods-b", "blackhole"]),
        OutputRouter.Aggregate(uid: "unrelated", subDeviceUIDs: ["speaker", "hdmi"]),
    ]

    private func route(_ output: String, capture: String = "blackhole") -> String? {
        OutputRouter.route(output: output, capture: capture, aggregates: aggregates)
    }

    func testPicksTheMultiOutputContainingTheCurrentOutput() {
        XCTAssertEqual(route("airpods-a"), "multi-airpods-a")
        XCTAssertEqual(route("airpods-b"), "multi-airpods-b")
        XCTAssertEqual(route("speaker"), "multi-speaker")
    }

    func testLeavesOutputAloneWhenAlreadyRouted() {
        XCTAssertNil(route("multi-airpods-b"))
    }

    func testLeavesOutputAloneWithoutASuitableDevice() {
        XCTAssertNil(route("hdmi"))
        // Capturing a microphone: no output device feeds it.
        XCTAssertNil(route("speaker", capture: "microphone"))
        XCTAssertNil(OutputRouter.route(output: "speaker", capture: "blackhole", aggregates: []))
    }

    func testAnAggregateWithoutTheCaptureDeviceIsNotAlreadyRouted() {
        // Sitting on some other aggregate is not "already routed"; and since no
        // aggregate contains both it and BlackHole, there is nothing to pick.
        XCTAssertNil(route("unrelated"))
    }
}

final class AppVersionTests: XCTestCase {
    func testReleaseShowsPlainVersion() {
        XCTAssertEqual(AppVersion.format(version: "0.1.2", isDebug: false), "v0.1.2")
    }

    func testLocalBuildIsMarked() {
        XCTAssertEqual(AppVersion.format(version: "0.1.0", isDebug: true), "v0.1.0 dev")
    }

    func testMissingVersion() {
        XCTAssertEqual(AppVersion.format(version: nil, isDebug: false), "v?")
    }
}

final class AudioInputDeviceTests: XCTestCase {
    private let devices = [
        AudioInputDevice(id: "a", name: "AirPods"),
        AudioInputDevice(id: "b2", name: "BlackHole 16ch"),
        AudioInputDevice(id: "b1", name: "BlackHole 2ch"),
    ]

    func testFragmentFindsTheDevice() {
        XCTAssertEqual(AudioInputDevice.match("blackhole", in: devices)?.id, "b2")
    }

    func testExactNameBeatsAnEarlierPartialMatch() {
        XCTAssertEqual(AudioInputDevice.match("BlackHole 2ch", in: devices)?.id, "b1")
    }

    func testNoMatch() {
        XCTAssertNil(AudioInputDevice.match("USB Mic", in: devices))
        XCTAssertNil(AudioInputDevice.match("", in: devices))
    }
}

final class TranscribeRequestTests: XCTestCase {
    private let base = URL(string: "http://gpu:8765")!

    func testLiveRequestHasNoPrompt() {
        let request = ASRClient.transcribeRequest(baseURL: base, beamSize: 5, translate: true, prompt: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://gpu:8765/transcribe?beam_size=5&translate=1")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testPromptTravelsInTheQuery() {
        let request = ASRClient.transcribeRequest(
            baseURL: base, beamSize: 10, translate: true, prompt: "昨日は雨&風+雪"
        )
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "昨日は雨&風+雪")
        XCTAssertEqual(items.first { $0.name == "beam_size" }?.value, "10")
        // A query parser reads a bare "+" as a space.
        XCTAssertFalse(request.url!.absoluteString.contains("+"))
    }

    func testEmptyPromptIsLeftOut() {
        let request = ASRClient.transcribeRequest(baseURL: base, beamSize: 5, translate: false, prompt: "")
        XCTAssertEqual(request.url?.absoluteString, "http://gpu:8765/transcribe?beam_size=5&translate=0")
    }
}

final class ReplayCorrectionTests: XCTestCase {
    private func caption(_ id: Int, _ text: String) -> Caption {
        Caption(id: id, japanese: text, ruby: [], english: "", moment: nil)
    }

    func testReplacesTheCaptionInPlace() {
        let captions = [caption(0, "一"), caption(1, "二"), caption(2, "三")]
        let (result, tail) = CaptionEngine.splice(
            [caption(3, "弐"), caption(4, "ニ")], into: captions, replacing: 1, after: nil
        )
        XCTAssertEqual(result.map(\.japanese), ["一", "弐", "ニ", "三"])
        XCTAssertEqual(tail, 4)
    }

    /// A sentence played back with a pause in it comes back as two
    /// utterances; the second belongs after the first, not at the end.
    func testASecondUtteranceOfTheSameReplayFollowsTheFirst() {
        let captions = [caption(0, "一"), caption(3, "弐"), caption(2, "三")]
        let (result, tail) = CaptionEngine.splice([caption(4, "ニ")], into: captions, replacing: 1, after: 3)
        XCTAssertEqual(result.map(\.japanese), ["一", "弐", "ニ", "三"])
        XCTAssertEqual(tail, 4)
    }

    func testAClearedCaptionIsHeardAsANewOne() {
        let (result, _) = CaptionEngine.splice([caption(4, "ニ")], into: [caption(3, "四")], replacing: 1, after: nil)
        XCTAssertEqual(result.map(\.japanese), ["四", "ニ"])
    }

    func testDeadlineCoversTheWholePlayback() {
        let now = Date(timeIntervalSince1970: 1000)
        var moment = VideoMoment(tabID: 1, url: "u", seconds: 60)
        moment.end = 64
        let deadline = CaptionEngine.replayDeadline(for: moment, from: now)
        // 4 s of sentence, the lead and tail it is played with, and the
        // time Chrome takes to get going.
        XCTAssertEqual(
            deadline.timeIntervalSince(now),
            4 + ChromeScript.seekLead + ChromeScript.seekTail + CaptionEngine.replayLatency, accuracy: 0.001
        )
        // Played at double speed, it is over sooner.
        moment.rate = 2
        XCTAssertLessThan(CaptionEngine.replayDeadline(for: moment, from: now), deadline)
    }

    func testASentenceWithoutAnEndIsGivenTheLongestUtterance() {
        let now = Date()
        let moment = VideoMoment(tabID: 1, url: "u", seconds: 60)
        XCTAssertGreaterThan(CaptionEngine.replayDeadline(for: moment, from: now).timeIntervalSince(now), 12)
    }
}

final class ReplayFragmentTests: XCTestCase {
    func testAFragmentAroundTheJumpIsNotTheSentence() {
        XCTAssertFalse(CaptionEngine.replayCovers(spoken: 0.4, expected: 3))
        XCTAssertTrue(CaptionEngine.replayCovers(spoken: 1.6, expected: 3))
        // Cut a little short by the stop, or by a pause in it, still counts.
        XCTAssertTrue(CaptionEngine.replayCovers(spoken: 2.2, expected: 3))
    }

    func testSentenceLengthComesFromItsMoment() {
        var moment = VideoMoment(tabID: 1, url: "u", seconds: 60)
        XCTAssertEqual(CaptionEngine.sentenceLength(of: moment), 12)
        moment.end = 63.5
        XCTAssertEqual(CaptionEngine.sentenceLength(of: moment), 3.5)
    }
}
