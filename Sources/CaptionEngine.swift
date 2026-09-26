import AVFoundation
import Observation

struct Caption: Identifiable, Equatable {
    let id: Int
    let japanese: String
    let ruby: [RubyToken]
    let english: String
    /// Where the sentence starts in the Chrome video it was heard from.
    var moment: VideoMoment?
}

/// Runs the pipeline: audio -> VAD -> utterances -> GPU server -> captions.
///
/// Everything here is on the main actor. The per-frame work is a 480-sample
/// RMS thirty times a second, and the slow parts (network) suspend rather than
/// block, so there is nothing worth the locking a background pipeline needs.
@MainActor
@Observable
final class CaptionEngine {
    enum Status: Equatable {
        case idle
        case connecting(String)
        case listening(String)
        case reconnecting
        case failed(String)
    }

    private(set) var status: Status = .idle {
        didSet {
            if status != oldValue { print("status: \(status)") }
        }
    }
    private(set) var captions: [Caption] = []
    private(set) var partialText = ""
    private(set) var inputLevel: Float = 0
    private(set) var speechThreshold: Float = 0
    private(set) var isSpeaking = false

    /// Where the video is at a given time, asked as each utterance starts so
    /// its captions can take the video back to it.
    var videoClock: (@MainActor (Date) async -> VideoMoment?)?

    var isRunning: Bool {
        switch status {
        case .idle, .failed: false
        case .connecting, .listening, .reconnecting: true
        }
    }

    var transcript: String {
        captions.map { "\($0.japanese)\n-> \($0.english)" }.joined(separator: "\n\n")
    }

    private static let remoteRetries = 4
    private static let remoteRetryDelay: UInt64 = 2_000_000_000
    /// Whisper's own default: the gains past it are small, and the caption
    /// would otherwise lag the video. Partials stay at 1, being a preview.
    static let liveBeamSize = 5
    /// A sentence heard again has no one waiting on it.
    static let replayBeamSize = 10
    /// How many earlier captions a replay's transcription is told about, so
    /// a name or a term heard before is heard the same way again.
    static let replayContextCaptions = 2
    /// Between the click and Chrome starting the sentence, with room for
    /// the video to load the part it jumped to.
    static let replayLatency: TimeInterval = 4
    /// An utterance heard on replay must be at least this share of the
    /// sentence's length to be taken as the sentence. Whatever else the
    /// player lets out around a jump, a fragment, is dropped: transcribed,
    /// it comes back as a made-up line.
    static let replayMinimumShare = 0.5

    private var session: ServerSession?
    private var source: AudioSource?
    private let outputRouter = OutputRouter()
    private var runTask: Task<Void, Never>?
    private var finalWorker: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    private var finals: AsyncStream<(id: Int, audio: Data)>.Continuation?
    private var serverLabel = "GPU"

    private var vad = VoiceActivityDetector()
    private var segmenter = UtteranceSegmenter()
    private var frameCount = 0
    private var nextCaptionID = 0
    /// Partials belong to the utterance being spoken. Once that utterance's
    /// final has landed, a late partial for it must not overwrite the screen.
    private var partialUtterance = -1
    private var settledUtterance = -1
    private var utteranceMoments: [Int: Task<VideoMoment?, Never>] = [:]
    /// A caption whose sentence is being played again from the video. Until
    /// the deadline, an utterance that starts is that sentence heard again,
    /// and what the server makes of it this time replaces the caption.
    private var replay: (captionID: Int, deadline: Date, expected: TimeInterval)?
    /// Utterances that are a replay: the caption each corrects and how long
    /// its sentence is.
    private var replayUtterances: [Int: (captionID: Int, expected: TimeInterval)] = [:]
    /// The last line written for each corrected caption, so a sentence that
    /// comes back as two utterances lands in order rather than the second
    /// one appending at the end.
    private var replayTails: [Int: Int] = [:]
    /// Held while captioning so the display doesn't sleep under the captions.
    private var activity: NSObjectProtocol?

    func start() {
        guard !isRunning else { return }
        runTask = Task { await run() }
    }

    /// Stop captioning and release the GPU. Returns the task doing the
    /// release, for a caller (quitting) that has to wait for it.
    @discardableResult
    func stop() -> Task<Void, Never> {
        runTask?.cancel()
        finalWorker?.cancel()
        partialTask?.cancel()
        runTask = nil
        finalWorker = nil
        partialTask = nil
        finals?.finish()
        finals = nil
        utteranceMoments = [:]
        replay = nil
        replayUtterances = [:]
        replayTails = [:]
        source?.stop()
        source = nil
        outputRouter.restore()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil

        partialText = ""
        isSpeaking = false
        inputLevel = 0
        status = .idle

        let session = self.session
        self.session = nil
        return Task { await session?.stop() }
    }

    func clear() {
        captions = []
        replayTails = [:]
    }

    /// The caption's sentence is about to be played again from the video:
    /// what is heard next is that sentence, and replaces the caption. A
    /// caption cleared or replaced meanwhile is left alone.
    func expectReplay(of caption: Caption) {
        guard isRunning, let moment = caption.moment else { return }
        replay = (caption.id, Self.replayDeadline(for: moment, from: Date()), Self.sentenceLength(of: moment))
        replayTails[caption.id] = nil
    }

    /// The playback did not happen after all.
    func cancelReplay(of caption: Caption) {
        if replay?.captionID == caption.id {
            replay = nil
        }
    }

    /// Speech of a replayed sentence starts before this: the sentence is
    /// played with a lead and a tail, and a caption's start is an estimate,
    /// so the whole playback counts rather than just its first seconds.
    nonisolated static func replayDeadline(for moment: VideoMoment, from now: Date) -> Date {
        let played = (sentenceLength(of: moment) + ChromeScript.seekLead + ChromeScript.seekTail)
            / max(moment.rate, 0.1)
        return now.addingTimeInterval(played + replayLatency)
    }

    /// How long the sentence takes to play, in video seconds.
    nonisolated static func sentenceLength(of moment: VideoMoment) -> TimeInterval {
        let end = moment.end ?? moment.seconds + UtteranceSegmenter.Config().maxUtterance
        return max(end - moment.seconds, 0)
    }

    /// Whether `spoken` seconds heard on replay can be the sentence that
    /// takes `expected` seconds, rather than a fragment around the jump.
    nonisolated static func replayCovers(spoken: TimeInterval, expected: TimeInterval) -> Bool {
        spoken >= expected * replayMinimumShare
    }

    private func run() async {
        let source = makeSource()
        if source is InputDeviceSource {
            status = .connecting("Checking audio input…")
            // macOS gates every input device behind the microphone
            // permission, BlackHole included.
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                status = .failed(
                    "Audio input access is off. Enable LiveTrans in "
                        + "System Settings > Privacy & Security > Microphone."
                )
                return
            }
        }

        let config = AppSettings.serverConfig
        let session = ServerSession(config: config)
        self.session = session
        status = .connecting("Connecting to \(config.sshHost)…")

        let client: ASRClient
        do {
            let (startedClient, health) = try await session.start { [weak self] message in
                Task { @MainActor in
                    guard let self, case .connecting = self.status else { return }
                    self.status = .connecting(message)
                }
            }
            client = startedClient
            serverLabel = ["GPU", health.asr, health.ollamaModel].compactMap { $0 }.joined(separator: " · ")
        } catch {
            // Stop pressed mid-connect: the cancelled requests fail like any
            // network error, but that is not a failure worth reporting.
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }

        let frames: AsyncStream<Data>
        do {
            frames = try source.start()
            self.source = source
            if let captureUID = (source as? InputDeviceSource)?.captureDeviceUID,
               UserDefaults.standard.bool(forKey: AppSettings.autoRouteOutput) {
                outputRouter.engage(captureUID: captureUID)
            }
        } catch {
            fail("Could not start audio: \(error.localizedDescription)")
            return
        }

        vad = VoiceActivityDetector()
        // A fresh segmenter numbers its utterances from zero again.
        segmenter = UtteranceSegmenter()
        partialUtterance = -1
        settledUtterance = -1
        startFinalWorker(client: client)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Live captioning"
        )
        status = .listening(serverLabel)

        for await frame in frames {
            process(frame, client: client)
        }
        // A file source simply runs out. An input device's stream only ends
        // when the device could not be reopened after a configuration change.
        if !Task.isCancelled, source is InputDeviceSource {
            fail("The audio input stopped. Check the input device in Settings, then press Start.")
        }
    }

    private func fail(_ message: String) {
        stop()
        status = .failed(message)
    }

    private func makeSource() -> AudioSource {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: AppSettings.demoAudioPath), !path.isEmpty {
            return FileSource(url: URL(fileURLWithPath: path))
        }
        #endif
        // No match (BlackHole not installed, say) falls back to the default
        // input.
        let name = UserDefaults.standard.string(forKey: AppSettings.inputDeviceName) ?? ""
        return InputDeviceSource(device: AudioInputDevice.matching(name))
    }

    private func process(_ frame: Data, client: ASRClient) {
        let isSpeech = vad.isSpeech(frame, inUtterance: segmenter.isActive)
        frameCount += 1
        if frameCount % 3 == 0 {
            // ~10 Hz is plenty for a level meter, and for picking up a
            // sensitivity change made in Settings while captioning.
            vad.speechRatio = AppSettings.speechRatio
            inputLevel = vad.lastRMS
            // The bar a frame has to clear right now, so the mark steps down
            // while an utterance is open.
            speechThreshold = segmenter.isActive ? vad.continuationThreshold : vad.threshold
        }

        for event in segmenter.process(frame: frame, isSpeech: isSpeech) {
            switch event {
            case .started(let utterance):
                isSpeaking = true
                if let replay {
                    if Date() <= replay.deadline {
                        replayUtterances[utterance] = (replay.captionID, replay.expected)
                    } else {
                        self.replay = nil
                    }
                }
                if let videoClock {
                    let now = Date()
                    utteranceMoments[utterance] = Task { await videoClock(now) }
                }
            case .partial(let audio, let utterance):
                requestPartial(audio, utterance: utterance, client: client)
            case .final(let audio, let utterance):
                isSpeaking = false
                let seconds = Double(audio.count / AudioFormat.frameBytes) * AudioFormat.frameDuration
                print(String(
                    format: "utterance %d: %.1f s, noise floor %.0f, threshold %.0f",
                    utterance, seconds, vad.noiseFloor ?? 0, vad.threshold
                ))
                finals?.yield((id: utterance, audio: audio))
            case .discarded(let utterance):
                isSpeaking = false
                print("utterance \(utterance) discarded: too brief to be speech")
                utteranceMoments[utterance] = nil
                replayUtterances[utterance] = nil
                settle(utterance)
            }
        }
    }

    /// At most one partial in flight. They are only a preview, so when the
    /// server is slower than the partial interval the stale one is skipped
    /// rather than queued behind.
    private func requestPartial(_ audio: Data, utterance: Int, client: ASRClient) {
        // A replay's preview would only show under the captions what is
        // about to replace one of them.
        guard partialTask == nil, replayUtterances[utterance] == nil else { return }
        partialTask = Task {
            defer { partialTask = nil }
            guard
                let result = try? await client.transcribe(pcm: audio, beamSize: 1, translate: false),
                !Task.isCancelled, utterance > settledUtterance, !result.japanese.isEmpty
            else { return }
            partialUtterance = utterance
            partialText = result.japanese
        }
    }

    /// Finals go through one queue so captions appear in the order spoken,
    /// even when a short utterance would otherwise overtake a long one.
    private func startFinalWorker(client: ASRClient) {
        let (stream, continuation) = AsyncStream.makeStream(of: (id: Int, audio: Data).self)
        finals = continuation
        finalWorker = Task {
            for await final in stream {
                await transcribeFinal(final.audio, utterance: final.id, client: client)
                settle(final.id)
            }
        }
    }

    private func transcribeFinal(_ audio: Data, utterance: Int, client: ASRClient) async {
        let moment = utteranceMoments.removeValue(forKey: utterance)
        // The moment is when the first speech was noticed, after the pre-roll.
        let spoken = Double(audio.count / AudioFormat.frameBytes) * AudioFormat.frameDuration
            - segmenter.config.preRoll - segmenter.config.postRoll
        let correcting = replayUtterances.removeValue(forKey: utterance)
        if let correcting, !Self.replayCovers(spoken: spoken, expected: correcting.expected) {
            print(String(
                format: "caption %d: %.1f s heard on replay of a %.1f s sentence, dropped as a fragment",
                correcting.captionID, spoken, correcting.expected
            ))
            return
        }
        let beamSize = correcting == nil ? Self.liveBeamSize : Self.replayBeamSize
        let prompt = correcting.map { replayPrompt(for: $0.captionID) }
        for attempt in 1...Self.remoteRetries {
            do {
                let result = try await client.transcribe(
                    pcm: audio, beamSize: beamSize, translate: true, prompt: prompt
                )
                guard !Task.isCancelled else { return }
                status = .listening(serverLabel)
                if result.lines.allSatisfy(\.ja.isEmpty) {
                    print("utterance \(utterance): the server heard no words")
                }
                let lines = captionLines(result, from: await moment?.value, spoken: spoken)
                if let correcting {
                    print(String(
                        format: "caption %d: %.1f s heard on replay of a %.1f s sentence",
                        correcting.captionID, spoken, correcting.expected
                    ))
                    correct(correcting.captionID, with: lines)
                } else {
                    captions.append(contentsOf: lines)
                }
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A restart takes a couple of seconds, so waiting beats
                // dropping: the audio is already buffered and nothing is lost.
                status = .reconnecting
                await session?.ensureUp()
                if attempt < Self.remoteRetries {
                    try? await Task.sleep(nanoseconds: Self.remoteRetryDelay)
                } else {
                    print("utterance \(utterance) dropped after \(attempt) attempts: \(error.localizedDescription)")
                }
            }
        }
    }

    private func captionLines(_ result: Transcription, from moment: VideoMoment?, spoken: TimeInterval) -> [Caption] {
        let lines = result.lines.filter { !$0.ja.isEmpty }
        let moments = Self.moments(of: lines.map(\.ja), from: moment, spoken: spoken)
        return zip(lines, moments).map { line, moment in
            print("\(line.ja)\n-> \(line.en)")
            defer { nextCaptionID += 1 }
            return Caption(
                id: nextCaptionID,
                japanese: line.ja,
                ruby: Furigana.annotate(line.ja),
                english: line.en,
                moment: moment
            )
        }
    }

    /// What the sentence was heard as this time takes the caption's place.
    /// Nothing heard leaves the caption as it was. The new lines get ids of
    /// their own: an analysis of the old text must not pass for one of the
    /// new.
    private func correct(_ captionID: Int, with lines: [Caption]) {
        guard !lines.isEmpty else {
            print("caption \(captionID): nothing heard on replay, kept")
            return
        }
        var lines = lines
        // A sentence heard again from the video is where the video was when
        // it was heard, but a moment lost to a Chrome hiccup is not worth
        // losing the ability to play the corrected sentence.
        if lines[0].moment == nil, let old = captions.first(where: { $0.id == captionID }) {
            lines[0].moment = old.moment
        }
        let (spliced, tail) = Self.splice(lines, into: captions, replacing: captionID, after: replayTails[captionID])
        captions = spliced
        replayTails[captionID] = tail
    }

    /// `lines` in place of the caption `replacing`, or after `tail`, the last
    /// line written for it, when the caption has already been replaced by an
    /// earlier utterance of the same playback. A caption that is gone
    /// (cleared) is heard as new captions at the end. Returns the captions
    /// and the id of the last line placed.
    nonisolated static func splice(
        _ lines: [Caption], into captions: [Caption], replacing captionID: Int, after tail: Int?
    ) -> ([Caption], tail: Int) {
        var captions = captions
        if let tail, let index = captions.firstIndex(where: { $0.id == tail }) {
            captions.insert(contentsOf: lines, at: index + 1)
        } else if let index = captions.firstIndex(where: { $0.id == captionID }) {
            captions.replaceSubrange(index...index, with: lines)
        } else {
            captions.append(contentsOf: lines)
        }
        return (captions, lines.last!.id)
    }

    /// The captions before the one being corrected, for the transcription to
    /// hear the sentence in context. Once part of the sentence has been
    /// placed, the rest follows on from that part.
    private func replayPrompt(for captionID: Int) -> String {
        let index = if let tail = replayTails[captionID], let placed = captions.firstIndex(where: { $0.id == tail }) {
            placed + 1
        } else {
            captions.firstIndex { $0.id == captionID } ?? captions.count
        }
        return captions[max(index - Self.replayContextCaptions, 0)..<index].map(\.japanese).joined()
    }

    /// Where each sentence of an utterance starts and ends. Only the
    /// utterance's start and length were noted, so the sentences are placed
    /// by their share of the text, which is close enough to land on the right
    /// sentence.
    nonisolated static func moments(of lines: [String], from start: VideoMoment?, spoken: TimeInterval) -> [VideoMoment?] {
        guard let start else { return lines.map { _ in nil } }
        let total = Double(max(lines.reduce(0) { $0 + $1.count }, 1))
        var before = 0
        return lines.map { line in
            var moment = start.advanced(by: max(spoken, 0) * Double(before) / total)
            before += line.count
            moment.end = start.advanced(by: max(spoken, 0) * Double(before) / total).seconds
            return moment
        }
    }

    private func settle(_ utterance: Int) {
        settledUtterance = max(settledUtterance, utterance)
        if partialUtterance <= settledUtterance {
            partialText = ""
        }
    }
}
