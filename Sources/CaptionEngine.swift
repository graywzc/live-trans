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
    /// How many earlier captions a re-hearing's transcription is told
    /// about, so a name or a term heard before is heard the same way again.
    static let replayContextCaptions = 2
    /// A correction keeps at least this share of the original's characters,
    /// in order. Hearing the sentence again changes a word or two; a line
    /// with nothing of the original in it was heard from somewhere else.
    static let replayMinimumResemblance = 0.4
    /// Lines heard over at least this share of a caption's stretch of the
    /// video are that caption heard again. Heard over less, but mostly
    /// inside it, they are a fragment of it.
    static let rehearingMinimumCover = 0.5

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
    /// The same, once Chrome has answered, for the partials to check.
    private var resolvedMoments: [Int: VideoMoment] = [:]
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
        resolvedMoments = [:]
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
                if let videoClock {
                    let now = Date()
                    utteranceMoments[utterance] = Task {
                        let moment = await videoClock(now)
                        if let moment { self.resolvedMoments[utterance] = moment }
                        return moment
                    }
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
                resolvedMoments[utterance] = nil
                settle(utterance)
            }
        }
    }

    /// At most one partial in flight. They are only a preview, so when the
    /// server is slower than the partial interval the stale one is skipped
    /// rather than queued behind.
    private func requestPartial(_ audio: Data, utterance: Int, client: ASRClient) {
        guard partialTask == nil else { return }
        // A preview of something already captioned would only show under
        // the captions what is about to replace one of them.
        if let moment = resolvedMoments[utterance],
           Self.isCaptioned(captions, from: moment, spoken: Self.seconds(of: audio)) {
            return
        }
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
        // The moment is when the first speech was noticed, after the pre-roll.
        let moment = await utteranceMoments.removeValue(forKey: utterance)?.value
        resolvedMoments[utterance] = nil
        let spoken = Self.seconds(of: audio) - segmenter.config.preRoll - segmenter.config.postRoll
        // Heard from a stretch of the video that has captions already: the
        // sentence played again from a caption, or the video played on from
        // there, or taken back. Nobody is waiting on it, so it can be heard
        // with care, and what it gives corrects those captions.
        let heardAgain = moment.map { Self.isCaptioned(captions, from: $0, spoken: spoken) } ?? false
        let beamSize = heardAgain ? Self.replayBeamSize : Self.liveBeamSize
        let prompt = heardAgain ? contextPrompt(before: moment!, spoken: spoken) : nil
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
                let lines = captionLines(result, from: moment, spoken: spoken)
                if heardAgain {
                    print(String(format: "utterance %d: %.1f s heard again", utterance, spoken))
                }
                captions = Self.merge(lines, into: captions, prompt: prompt ?? "")
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
        let moments = Self.moments(of: lines, from: moment, spoken: spoken, preRoll: segmenter.config.preRoll)
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

    nonisolated static func seconds(of audio: Data) -> TimeInterval {
        Double(audio.count / AudioFormat.frameBytes) * AudioFormat.frameDuration
    }

    /// How much of the video, in seconds, `a` and `b` both cover: zero when
    /// they don't, or are not on the same page.
    nonisolated static func overlap(_ a: VideoMoment, _ b: VideoMoment) -> TimeInterval {
        guard a.tabID == b.tabID, a.url == b.url, let aEnd = a.end, let bEnd = b.end else { return 0 }
        return max(min(aEnd, bEnd) - max(a.seconds, b.seconds), 0)
    }

    /// Whether `spoken` seconds heard from `moment` are of a stretch of the
    /// video that has captions.
    nonisolated static func isCaptioned(_ captions: [Caption], from moment: VideoMoment, spoken: TimeInterval) -> Bool {
        let span = moment.advanced(by: max(spoken, 0)).seconds
        var heard = moment
        heard.end = span
        return captions.contains { caption in
            caption.moment.map { overlap(heard, $0) > 0 } ?? false
        }
    }

    /// `lines` heard from the video put among `captions`. A line heard over
    /// a stretch the captions cover is one of them heard again: it takes
    /// their place, unless it is only the context the model was handed, or
    /// keeps too little of them, as the model gives over sound that isn't
    /// speech; then they are kept as they were. A line mostly inside a
    /// caption without covering it is a fragment, and dropped. Any other
    /// line is new, and goes in the order of the video. The lines replacing
    /// captions have ids of their own: an analysis of the old text must not
    /// pass for one of the new.
    nonisolated static func merge(_ lines: [Caption], into captions: [Caption], prompt: String) -> [Caption] {
        // Lines and captions that overlap in the video, grouped: a sentence
        // can come back as two lines, and two as one.
        var parent = Array(0..<(lines.count + captions.count))
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        var overlaps: [Int: TimeInterval] = [:]
        for (li, line) in lines.enumerated() {
            guard let heard = line.moment else { continue }
            for (ci, caption) in captions.enumerated() {
                guard let old = caption.moment else { continue }
                let shared = overlap(heard, old)
                guard shared > 0 else { continue }
                overlaps[li, default: 0] += shared
                parent[root(lines.count + ci)] = root(li)
            }
        }
        var groups: [Int: (lines: [Int], captions: [Int])] = [:]
        for li in lines.indices { groups[root(li), default: ([], [])].lines.append(li) }
        for ci in captions.indices { groups[root(lines.count + ci), default: ([], [])].captions.append(ci) }

        var replacing: [Int: [Caption]] = [:]  // first caption index -> its group's lines
        var removed = Set<Int>()
        var new: [Caption] = []
        for group in groups.values where !group.lines.isEmpty {
            let heard = group.lines.map { lines[$0] }
            let text = heard.map(\.japanese).joined()
            guard !group.captions.isEmpty else {
                new.append(contentsOf: heard)
                continue
            }
            let originals = group.captions.map { captions[$0] }
            let original = originals.map(\.japanese).joined()
            let shared = group.lines.reduce(0) { $0 + (overlaps[$1] ?? 0) }
            let length = { (moments: [Caption]) in
                moments.reduce(0.0) { $0 + (($1.moment?.end ?? 0) - ($1.moment?.seconds ?? 0)) }
            }
            if shared >= length(originals) * rehearingMinimumCover {
                if isEcho(text, of: prompt) {
                    print("heard again as its context, kept: \(original)")
                } else if resemblance(of: text, to: original) < replayMinimumResemblance {
                    print("heard again as something else, kept: \(original) (heard: \(text))")
                } else {
                    print("heard again: \(original) -> \(text)")
                    replacing[group.captions.min()!] = heard
                    removed.formUnion(group.captions)
                }
            } else if shared >= length(heard) * rehearingMinimumCover {
                print("a fragment of a caption, dropped: \(text)")
            } else {
                new.append(contentsOf: heard)
            }
        }

        var result: [Caption] = []
        for (ci, caption) in captions.enumerated() {
            if let lines = replacing[ci] { result.append(contentsOf: lines) }
            if !removed.contains(ci) { result.append(caption) }
        }
        // New lines go before the first caption of the same page that starts
        // after they end, else at the end: a sentence missed live and heard
        // on the way back lands where it was said, and a live one is last.
        for line in new {
            let at = line.moment.flatMap { heard in
                result.firstIndex { caption in
                    guard let old = caption.moment, old.tabID == heard.tabID, old.url == heard.url else { return false }
                    return old.seconds > (heard.end ?? heard.seconds)
                }
            }
            result.insert(line, at: at ?? result.count)
        }
        return result
    }

    /// Whether `heard` is only the context the model was given, which it
    /// gives back over sound that isn't speech.
    nonisolated static func isEcho(_ heard: String, of prompt: String) -> Bool {
        let heard = content(of: heard)
        return !heard.isEmpty && content(of: prompt).contains(heard)
    }

    /// The share of `original`'s characters that `heard` keeps, in order.
    nonisolated static func resemblance(of heard: String, to original: String) -> Double {
        let a = Array(content(of: original)), b = Array(content(of: heard))
        guard !a.isEmpty else { return 1 }
        // Longest common subsequence, one row at a time.
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }

    /// The text without the punctuation and spaces that vary between two
    /// hearings of the same words.
    private nonisolated static func content(of text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// The captions before the stretch about to be heard again, for the
    /// transcription to hear it in context.
    private func contextPrompt(before moment: VideoMoment, spoken: TimeInterval) -> String {
        var heard = moment
        heard.end = moment.advanced(by: max(spoken, 0)).seconds
        let index = captions.firstIndex { caption in
            caption.moment.map { Self.overlap(heard, $0) > 0 } ?? false
        } ?? captions.count
        return captions[max(index - Self.replayContextCaptions, 0)..<index].map(\.japanese).joined()
    }

    /// Where each sentence of an utterance starts and ends. `start` is when
    /// the first speech was heard, and the audio sent began `preRoll`
    /// earlier, so a sentence the server placed in that audio is placed
    /// from there. One it could not place is put by its share of the text,
    /// which is close enough to land on the right sentence.
    nonisolated static func moments(
        of lines: [CaptionPair], from start: VideoMoment?, spoken: TimeInterval, preRoll: TimeInterval = 0
    ) -> [VideoMoment?] {
        guard let start else { return lines.map { _ in nil } }
        let total = Double(max(lines.reduce(0) { $0 + $1.ja.count }, 1))
        var before = 0
        return lines.map { line in
            var moment: VideoMoment
            if let from = line.start, let to = line.end, to > from {
                moment = start.advanced(by: max(from - preRoll, 0))
                moment.end = start.advanced(by: max(to - preRoll, 0)).seconds
            } else {
                moment = start.advanced(by: max(spoken, 0) * Double(before) / total)
                moment.end = start.advanced(by: max(spoken, 0) * Double(before + line.ja.count) / total).seconds
            }
            before += line.ja.count
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
