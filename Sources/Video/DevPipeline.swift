import Foundation
import Observation

/// The dev mode of captioning ahead: one step of the pipeline run on its
/// own, through the GPU host, over the whole of a Chrome video's audio,
/// for looking at what the step does. The host fetches the video from its
/// start and runs the step over everything it has, again as more arrives;
/// what it finds goes on a timeline in the Dev panel, where a stretch
/// can be picked out and heard from the fetched audio. No captions are
/// made, and the live listener goes on as it is.
@MainActor
@Observable
final class DevPipeline {
    /// The steps that can be run, in the pipeline's order.
    enum Step: String, CaseIterable, Identifiable {
        /// Silero finding where the speech is.
        case speech
        /// The same, with FireRedVAD in Silero's place.
        case speechFireRed = "speech-firered"
        /// The same, with FireRedVAD and pyannote's segmentation model
        /// averaged.
        case speechMean = "speech-mean"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech: "1 · Speech (Silero)"
            case .speechFireRed: "1 · Speech (FireRedVAD)"
            case .speechMean: "1 · Speech (FireRedVAD + pyannote)"
            }
        }

        /// What finds the speech in the step.
        var finder: String {
            switch self {
            case .speech: "Silero"
            case .speechFireRed: "FireRedVAD"
            case .speechMean: "FireRedVAD and pyannote together"
            }
        }
    }

    struct Job: Equatable {
        let id: String
        let tabID: Int
        let page: String
        let step: Step
        var duration: Double?
        /// How far the audio has come, from the video's start.
        var fetched = 0.0
        /// Up to where the step has looked.
        var analysed = 0.0
        /// Up to where the words have been heard; whether re-timed.
        var worded = 0.0
        var aligned = false
        /// Whether the speakers have been told apart.
        var spoken = false
        /// How many texts the other recognizers have given.
        var others = 0
        var state = "running"
        /// Whether the host was told to hold the step.
        var paused = false
        /// The audio came from the host's cache rather than a fetch.
        var cached = false
        /// How many of the job's captions are on the list, and what the
        /// host says of the captions ("running", "done", "failed: ...").
        var seenLines = 0
        var captions = "running"
        /// What the host holds of the video for the phone ("none",
        /// "running", "done", "failed: ..."), and seconds of it so far.
        var bundle = "none"
        var bundleFetched = 0.0
        /// Where the phone fetches the host's bundles, once the host serves
        /// them, or why it could not.
        var bundleURL: String?
        var bundleServeError: String?
    }

    /// What FireRedVAD's event model hears besides speech, drawn over the
    /// stretches of speech to tell a song or a score from talk.
    struct SoundEvents: Equatable {
        var singing: [ClosedRange<Double>] = []
        /// Music with neither singing nor speech in it.
        var music: [ClosedRange<Double>] = []

        var isEmpty: Bool { singing.isEmpty && music.isEmpty }
    }

    static let probeInterval: TimeInterval = 3
    static let pollInterval: TimeInterval = 1

    private(set) var job: Job?
    /// Where the speech is, as the step found it.
    private(set) var speech: [ClosedRange<Double>] = []
    /// What else the step heard, when FireRedVAD is in it.
    private(set) var events = SoundEvents()
    /// The episode's official subtitles, when the host has them, to set
    /// beside the step's captions; and the page they are of.
    private(set) var reference: [ReferenceLine] = []
    private(set) var referencePage: String?
    @ObservationIgnored private var matched: (key: [Int], lines: [Int: [String]]) = ([], [:])
    /// The words Whisper alone hears over the audio, to judge the step by.
    private(set) var words: [HeardWord] = []
    /// Who speaks when, as DiariZen tells the voices apart.
    private(set) var speakers: [SpeakerTurn] = []
    /// The captions heard again by the other recognizers.
    private(set) var others: [OtherHearing] = []
    /// Their texts with readings, by text, made once each.
    @ObservationIgnored private var otherRuby: [String: [RubyToken]] = [:]
    /// Off at launch, like captioning ahead.
    private(set) var isPaused = true
    /// The stretch of the video picked out on the timeline.
    var selection: ClosedRange<Double>?
    /// Where the pointer was put on the timeline by a click, for playing
    /// from there.
    private(set) var cursor: Double?
    /// The pointer has been put somewhere since Space was last pressed, so
    /// the next press plays from there rather than pausing or resuming;
    /// until then the pointer stays where it was put, and after it goes
    /// with the video.
    private(set) var cursorArmed = false
    /// Where Space last sent the video, and when: until the video says it
    /// is there, the pointer stays put rather than going back to where the
    /// video was.
    private(set) var playedFrom: (seconds: Double, at: Date)?
    let player = ClipPlayer()

    /// The step run, kept across launches. Choosing another while a job
    /// runs stops that job, and the chosen step starts over the same video,
    /// from the audio the host kept of it.
    var step = Step(rawValue: UserDefaults.standard.string(forKey: AppSettings.pipelineStep) ?? "") ?? .speech {
        didSet {
            guard step != oldValue else { return }
            UserDefaults.standard.set(step.rawValue, forKey: AppSettings.pipelineStep)
            lastProbe = .distantPast
            Task { await tick() }
        }
    }

    var isActive: Bool { job != nil }

    private let engine: CaptionEngine
    private let video: ChromeVideo
    private var loop: Task<Void, Never>?
    private var isTicking = false
    private var lastProbe = Date.distantPast
    /// Pages the host could not fetch or run a step over, with the step:
    /// not tried again with that step until the app is relaunched. Another
    /// step may still work there (FireRedVAD fails where its files are
    /// missing, Silero does not).
    private var failedPages: Set<String> = []

    private static func failure(_ page: String, _ step: Step) -> String { "\(step.rawValue) \(page)" }

    /// Whether the app is in dev mode: see `SidePanel.isDev`.
    var isDev: @MainActor () -> Bool = { false }

    init(engine: CaptionEngine, video: ChromeVideo) {
        self.engine = engine
        self.video = video
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// Runs the step, or holds it: the host stops looking and goes on
    /// fetching; taken up again, it goes on from where it was.
    func toggle() {
        isPaused.toggle()
        lastProbe = .distantPast
        Task { await tick() }
    }

    /// Dev mode's Load: runs the step over the Chrome video, which takes
    /// from the host's cache whatever it made before over the video, and
    /// makes only what is missing.
    func load() {
        isPaused = false
        lastProbe = .distantPast
        Task { await tick() }
    }

    /// Holds the step, as when captioning stops.
    func hold() {
        isPaused = true
    }

    /// Dev mode's Re-run: has the host forget what it kept of the job's
    /// video, then makes all of it again from a fresh fetch.
    func rerun() {
        guard let client = engine.client, let current = job else { return }
        Task {
            do {
                _ = try await client.clearDevCache(page: current.page)
            } catch {
                ActivityLog.tell("Could not forget this video's cache: \(error.localizedDescription)")
                return
            }
            await stopJob()
            engine.clear()
            speech = []
            events = SoundEvents()
            words = []
            speakers = []
            others = []
            selection = nil
            ActivityLog.tell("Forgot this video's cache: making all of it again")
            isPaused = false
            lastProbe = .distantPast
            await tick()
        }
    }

    /// The audio the job holds, when the video at `playhead` is its own.
    func fetched(on playhead: VideoMoment?) -> ClosedRange<Double>? {
        guard let job, let playhead, playhead.tabID == job.tabID, playhead.url == job.page, job.fetched > 0 else {
            return nil
        }
        return 0...job.fetched
    }

    /// Whether the video at `playhead` is the one the job is of.
    func isOnJob(_ playhead: VideoMoment?) -> Bool {
        guard let job, let playhead else { return false }
        return playhead.tabID == job.tabID && playhead.url == job.page
    }

    /// Has the host forget the videos and findings dev mode kept, and says
    /// how many there were.
    func forgetCache() {
        guard let client = engine.client else { return }
        Task {
            do {
                let count = try await client.clearDevCache()
                ActivityLog.tell(count == 0 ? "The host had nothing cached" : "The host forgot \(count) cached video\(count == 1 ? "" : "s")")
            } catch {
                ActivityLog.tell("Could not clear the host's cache: \(error.localizedDescription)")
            }
        }
    }

    /// Puts the pointer at `seconds` of the video, for Space to play from.
    func place(cursor seconds: Double) {
        cursor = max(seconds, 0)
        cursorArmed = true
    }

    /// Space: plays the Chrome video from the pointer when it has been put
    /// somewhere since the last press, and says so; otherwise nothing, and
    /// Space does what it always does. Without a video to play, the fetched
    /// audio is heard from there instead, for as much as the host gives.
    func playFromCursor() -> Bool {
        guard cursorArmed, let cursor, let job else { return false }
        cursorArmed = false
        let moment = VideoMoment(tabID: job.tabID, url: job.page, seconds: cursor)
        if video.send(.seek(moment, exact: true)) {
            playedFrom = (cursor, Date())
            ActivityLog.tell("Playing the video from \(Self.clock(cursor))")
        } else {
            hear(cursor...min(cursor + 120, job.fetched))
        }
        return true
    }

    /// Plays the selected stretch from the fetched audio, on the device
    /// being listened on, or stops it.
    func hearSelection() {
        if player.isPlaying {
            player.stop()
            return
        }
        guard let selection else { return }
        hear(selection)
    }

    private func hear(_ stretch: ClosedRange<Double>) {
        guard let job, let client = engine.client else { return }
        let from = max(stretch.lowerBound, 0), to = min(stretch.upperBound, max(job.fetched, from))
        guard to > from else { return }
        ActivityLog.tell("Hearing \(Self.clock(from))–\(Self.clock(to)) from the fetched audio")
        let player = player
        Task {
            do {
                let wav = try await client.prefetchAudio(job: job.id, from: from, to: to)
                try player.play(try WAVClip(data: wav), on: ClipPlayer.listeningDeviceUID())
            } catch {
                ActivityLog.tell("Could not hear \(Self.clock(from))–\(Self.clock(to)): \(error.localizedDescription)")
            }
        }
    }

    /// A job and its findings put in place without a host, for tests and
    /// previews.
    func show(
        job: Job, speech: [ClosedRange<Double>], events: SoundEvents = SoundEvents(), words: [HeardWord] = [],
        speakers: [SpeakerTurn] = []
    ) {
        self.job = job
        self.speech = speech
        self.events = events
        self.words = words
        self.speakers = speakers
    }

    /// Plays the selected stretch in the Chrome video, which pauses at its
    /// end: the stretch itself, with no lead or tail.
    func playSelectionInChrome() {
        guard let selection, let job else { return }
        var moment = VideoMoment(tabID: job.tabID, url: job.page, seconds: selection.lowerBound)
        moment.end = selection.upperBound
        guard video.send(.seek(moment, exact: true)) else { return }
        ActivityLog.tell("Playing \(Self.clock(selection.lowerBound))–\(Self.clock(selection.upperBound)) in Chrome")
    }

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        guard engine.isRunning, engine.serverCanPrefetch, let client = engine.client, isDev() else {
            await stopJob()
            return
        }
        guard let current = job else {
            guard !isPaused, Date().timeIntervalSince(lastProbe) >= Self.probeInterval else { return }
            lastProbe = Date()
            guard let probe = await video.probeMedia(), probe.isFetchable, !failedPages.contains(Self.failure(probe.page, step)) else {
                return
            }
            await startJob(for: probe, client: client)
            return
        }
        if current.step != step {
            // Another step was chosen: this job goes, and the next tick
            // starts the chosen one over the audio the host kept. The host
            // keeps it only once the fetch has ended unstopped, so while the
            // audio is still coming the job is held (the GPU let go, the
            // fetch going on) and the switch waits for it.
            if let status = try? await client.prefetchStatus(job: current.id, since: current.seenLines), status.fetching == true {
                guard job?.id == current.id else { return }
                job?.fetched = max(status.fetched, 0)
                if !current.paused, (try? await client.setPrefetch(job: current.id, paused: true)) != nil {
                    job?.paused = true
                    ActivityLog.tell("Step \(step.title) starts once the video is fetched")
                }
                return
            }
            await stopJob()
            speech = []
            events = SoundEvents()
            words = []
            speakers = []
            others = []
            selection = nil
            return
        }
        if current.paused != isPaused {
            do {
                try await client.setPrefetch(job: current.id, paused: isPaused)
                if job?.id == current.id { job?.paused = isPaused }
            } catch {
                print("step \(isPaused ? "pause" : "resume"): \(error.localizedDescription)")
                return
            }
        }
        do {
            let status = try await client.prefetchStatus(job: current.id, since: current.seenLines)
            guard var updated = job, updated.id == current.id else { return }
            // The captions the step's speech finder led to, on the caption
            // list as production's would be.
            if !status.lines.isEmpty {
                engine.add(status.lines, tabID: current.tabID, url: current.page, heardAgain: false)
            }
            updated.seenLines = status.count
            if let captions = status.captions, captions != updated.captions {
                updated.captions = captions
                if captions == "done" {
                    ActivityLog.tell("Step \(current.step.title): \(status.count) captions, the whole video")
                } else if captions.hasPrefix("failed") {
                    ActivityLog.tell("Step \(current.step.title): captions \(captions)")
                }
            }
            updated.fetched = max(status.fetched, 0)
            updated.duration = status.duration ?? updated.duration
            updated.state = status.state
            if status.cached == true, !updated.cached {
                updated.cached = true
                ActivityLog.tell("The host had the video's audio from before: no fetch")
            }
            let analysed = status.analysed ?? 0
            let worded = status.worded ?? 0
            if analysed > updated.analysed || status.state == "done" && analysed != updated.analysed
                || worded > updated.worded || (status.aligned ?? false) != updated.aligned
                || (status.speakers ?? false) != updated.spoken || (status.others ?? 0) != updated.others {
                let findings = try await client.stepFindings(job: current.id)
                guard job?.id == current.id else { return }
                speech = findings.stretches
                events = findings.soundEvents
                words = findings.words ?? []
                speakers = findings.speakers ?? []
                others = findings.others ?? []
                updated.others = status.others ?? 0
                updated.analysed = findings.analysed
                updated.worded = findings.worded ?? 0
                updated.aligned = findings.aligned ?? false
                updated.spoken = findings.speakers != nil
            }
            if let bundle = status.bundle, bundle != updated.bundle {
                if let news = Self.phoneCopyNews(from: updated.bundle, to: bundle) { ActivityLog.tell(news) }
                updated.bundle = bundle
            }
            updated.bundleFetched = status.bundleFetched ?? 0
            if let news = Self.phoneAddressNews(
                fromURL: updated.bundleURL, error: updated.bundleServeError,
                toURL: status.bundleURL, error: status.bundleServeError
            ) {
                ActivityLog.tell(news)
            }
            updated.bundleURL = status.bundleURL
            updated.bundleServeError = status.bundleServeError
            job = updated
            if status.state == "failed" {
                ActivityLog.tell("Step \(current.step.title) failed: \(status.error ?? "unknown")")
                failedPages.insert(Self.failure(current.page, current.step))
                job = nil
            }
        } catch {
            print("step status: \(error.localizedDescription)")
        }
    }

    // MARK: The video kept for the phone

    /// Whether the host can be asked to keep the job's video for the
    /// phone: the step's captions have reached the end, and it is not
    /// fetching the video already.
    var canKeepForPhone: Bool {
        guard let job else { return false }
        return job.captions == "done" && job.bundle != "running"
    }

    /// What to tell when the host's word on the phone's copy changes;
    /// nothing for the states the control itself shows.
    static func phoneCopyNews(from old: String, to new: String) -> String? {
        guard new != old else { return nil }
        if new == "done" { return "The video is on the host for the iPhone, with its captions" }
        if new.hasPrefix("failed") { return "Keeping the video for the iPhone \(new)" }
        return nil
    }

    /// What to tell when the host's word on where the phone fetches its
    /// videos changes: the address once the host serves them, the reason
    /// once it could not; nothing for the same word again.
    static func phoneAddressNews(fromURL oldURL: String?, error oldError: String?, toURL url: String?, error: String?)
        -> String?
    {
        if let url, url != oldURL {
            return "The iPhone app fetches the host's videos from \(url): enter it as the host in its Settings"
        }
        if let error, error != oldError {
            return "The host could not serve its videos to the iPhone (\(error)): "
                + "let the server's user run tailscale with sudo without a password, or serve the dev cache folder yourself"
        }
        return nil
    }

    /// Has the host keep the job's video for the phone, with its captions:
    /// fetched as it is, beside the audio in the dev cache, with the tab's
    /// title for the phone's list. Dev mode only, as the whole cache is.
    func keepForPhone() {
        guard let client = engine.client, let current = job else { return }
        let title = video.tabs.first { $0.id == current.tabID }?.title
            ?? video.pinned.flatMap { $0.id == current.tabID ? $0.title : nil }
        Task {
            // The media playing on the page now goes with the ask, not the
            // one the job began with: a job restored from the cache never
            // fetched its link, which may be a pre-roll ad's. The host
            // judges its length against the captions.
            let playing = await video.probeMedia().flatMap { $0.page == current.page ? $0 : nil }
            do {
                _ = try await client.keepForPhone(
                    job: current.id, title: title, url: playing?.mediaURL, duration: playing?.duration
                )
                if job?.id == current.id {
                    job?.bundle = "running"
                    job?.bundleFetched = 0
                }
                ActivityLog.tell("Keeping the video for the iPhone: the host is fetching it as it is")
            } catch {
                ActivityLog.tell("Could not keep the video for the iPhone: \(error.localizedDescription)")
            }
        }
    }

    /// Has the host forget the phone's copy of the job's video, the video
    /// and its captions beside it, keeping the audio and the findings.
    func forgetPhoneCopy() {
        guard let client = engine.client, let current = job else { return }
        Task {
            do {
                let count = try await client.clearDevCache(page: current.page, bundleOnly: true)
                if job?.id == current.id {
                    job?.bundle = "none"
                    job?.bundleFetched = 0
                }
                ActivityLog.tell(
                    count == 0 ? "The host had no copy of this video for the iPhone"
                        : "The host forgot the iPhone's copy of this video"
                )
            } catch {
                ActivityLog.tell("Could not forget the iPhone's copy: \(error.localizedDescription)")
            }
        }
    }

    private func startJob(for probe: MediaProbe, client: ASRClient) async {
        let step = step
        var headers = ["User-Agent": probe.userAgent]
        if probe.mediaURL != nil { headers["Referer"] = probe.page }
        do {
            let id = try await client.startPrefetch(
                url: probe.mediaURL, page: probe.page, headers: headers, duration: probe.duration, start: 0,
                step: step.rawValue
            )
            job = Job(id: id, tabID: probe.tabID, page: probe.page, step: step, duration: probe.duration)
            // The list shows this step's captions alone.
            engine.clear()
            if referencePage != probe.page {
                referencePage = probe.page
                reference = await client.reference(page: probe.page)
                if !reference.isEmpty {
                    ActivityLog.tell("\(reference.count) official subtitle lines to set beside the captions")
                }
            }
            speech = []
            events = SoundEvents()
            words = []
            speakers = []
            others = []
            selection = nil
            cursor = nil
            cursorArmed = false
            let length = probe.duration.map { ", \(Self.clock($0)) long" } ?? ""
            ActivityLog.tell("Step \(step.title): fetching the whole video\(length), from its start")
            print("step \(step.rawValue) \(id): \(probe.mediaURL ?? probe.page)")
        } catch {
            ActivityLog.tell("Step \(step.title) could not start: \(error.localizedDescription)")
            failedPages.insert(Self.failure(probe.page, step))
        }
    }

    private func stopJob() async {
        guard let job else { return }
        self.job = nil
        player.stop()
        await engine.client?.stopPrefetch(job: job.id)
    }

    /// The official subtitle lines matched to `caption`, joined, or nil.
    func official(for caption: Caption) -> String? {
        guard !reference.isEmpty else { return nil }
        let key = [engine.captions.count, engine.captions.first?.id ?? -1, engine.captions.last?.id ?? -1, reference.count]
        if matched.key != key {
            matched = (key, Self.match(reference, to: engine.captions))
        }
        return matched.lines[caption.id].map { $0.joined(separator: " ") }
    }

    /// What the other recognizers heard over `caption`, as each is shown:
    /// those that have heard it, in OtherHearing.shown's order.
    /// Each as a caption of its own, for analysing: the caption's moment,
    /// and an id of its own no caption has (below zero).
    func others(for caption: Caption) -> [(label: String, sentence: Caption)] {
        Self.heard(others, over: caption).enumerated().map { index, other in
            let ruby = otherRuby[other.text] ?? Furigana.annotate(other.text)
            otherRuby[other.text] = ruby
            let sentence = Caption(
                id: Self.otherID(of: caption.id, index), japanese: other.text, ruby: ruby, english: "", moment: caption.moment
            )
            return (other.label, sentence)
        }
    }

    /// The id the `index`th other recognizer's line under caption `id` is
    /// analysed by: below zero, apart from every caption's and each other's.
    nonisolated static func otherID(of id: Int, _ index: Int) -> Int {
        -(id * (OtherHearing.shown.count + 1) + index + 1)
    }

    /// The one of `others` heard over `caption`'s own stretch (the host
    /// tells each by the caption's times), as `others(for:)` gives it.
    nonisolated static func heard(_ others: [OtherHearing], over caption: Caption) -> [(label: String, text: String)] {
        guard let moment = caption.moment, let end = moment.end,
              let heard = others.first(where: { abs($0.start - moment.seconds) < 0.01 && abs($0.end - end) < 0.01 })
        else { return [] }
        return OtherHearing.shown.compactMap { shown in heard[keyPath: shown.text].map { (shown.label, $0) } }
    }

    /// Each official line given to the caption it overlaps most in time,
    /// when they overlap by 0.3 s or half the shorter of the two: by
    /// caption id, the lines in order. A line overlapping no caption is
    /// left out.
    nonisolated static func match(_ lines: [ReferenceLine], to captions: [Caption]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        for line in lines {
            var best: (id: Int, overlap: Double)?
            for caption in captions {
                guard let moment = caption.moment, let end = moment.end else { continue }
                let overlap = min(end, line.end) - max(moment.seconds, line.start)
                let shorter = min(end - moment.seconds, line.end - line.start)
                guard overlap > 0, overlap >= min(0.3, shorter / 2) else { continue }
                if best == nil || overlap > best!.overlap { best = (caption.id, overlap) }
            }
            if let best { result[best.id, default: []].append(line.text) }
        }
        return result
    }

    /// "4:05.3", a place in the video to the tenth, as the host tells it.
    nonisolated static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        return String(format: "%d:%04.1f", tenths / 600, Double(tenths % 600) / 10)
    }
}
