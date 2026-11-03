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
        /// Up to where k2's captions are made.
        var ready = 0.0
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
        /// What the host is busy with for it right now.
        var running: [String] = []
        /// Whether the other recognizers are done, translated too, which
        /// the host waits for before keeping the video.
        var othersReady = true
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
    /// The recognizer picked per caption of this video, by where it starts,
    /// and what keeps them with the host; none in the Mac's memory after
    /// the video.
    private(set) var picks: [Int: String] = [:]
    @ObservationIgnored private var pickBook: PickBook?
    /// Off at launch, until Start or Load.
    private(set) var isPaused = true
    /// Why the host could not fetch or run over the video, as
    /// `Prefetcher.problem`; kept until a job starts, as such a video is
    /// not tried again.
    private(set) var problem: String?
    /// The videos the host keeps captions of, as it last listed them.
    private(set) var processed: [ProcessedVideo] = []
    /// The one of them chosen under the captions, which Load opens in
    /// Chrome; nil for a Chrome tab.
    var picked: ProcessedVideo?
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
    var step = Step(rawValue: UserDefaults.standard.string(forKey: AppSettings.pipelineStep) ?? "") ?? .speechMean {
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

    /// Asks the host what it has processed.
    func refreshProcessed() async {
        guard let listed = await ProcessedVideo.list(host: AppSettings.serverConfig.sshHost) else { return }
        processed = listed
    }

    /// Whether the host keeps captions of the video at `page`.
    func isProcessed(_ page: String?) -> Bool {
        processed.contains { $0.page == page }
    }

    /// Nothing is offered once out of Default.
    func forgetProcessed() {
        processed = []
        picked = nil
    }

    /// Dev mode's Start and Load: runs the step over the video, which takes
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
            forgetPicks()
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

    /// How far each recognizer has captioned the video at `playhead`, when
    /// it is the job's: k2's, then the others', as `reached(...)` tells it.
    func reached(on playhead: VideoMoment?) -> [(label: String, seconds: Double)] {
        guard let job, isOnJob(playhead) else { return [] }
        return Self.reached(
            captions: job.captions, ready: job.ready, total: Self.total(of: job), own: ownCaptions(of: job).map(\.range),
            others: others
        )
    }

    /// How far each recognizer's text has been translated in the video at
    /// `playhead`, when it is the job's, as `translated(...)` tells it.
    func translated(on playhead: VideoMoment?) -> [(label: String, seconds: Double)] {
        guard let job, isOnJob(playhead) else { return [] }
        return Self.translated(captions: job.captions, total: Self.total(of: job), own: ownCaptions(of: job), others: others)
    }

    /// Where telling the speakers apart is in the video at `playhead`, when
    /// it is the job's.
    func speakerState(on playhead: VideoMoment?) -> SpeakerState? {
        guard let job, isOnJob(playhead) else { return nil }
        if job.spoken { return .done }
        return job.running.contains("Speaker detection") ? .running : .waiting
    }

    /// The host tells the speakers apart once, over all the audio, after
    /// the fetch: nothing to show of it until then.
    enum SpeakerState: Equatable {
        case waiting, running, done
    }

    private static func total(of job: Job) -> Double {
        max(job.duration ?? 0, job.fetched)
    }

    /// The job's captions on the list: where each is, and whether it has
    /// its translation.
    private func ownCaptions(of job: Job) -> [(range: ClosedRange<Double>, english: Bool)] {
        engine.captions.compactMap { caption in
            guard let moment = caption.moment, moment.tabID == job.tabID, moment.url == job.page, let end = moment.end
            else { return nil }
            return (moment.seconds...max(end, moment.seconds), !caption.english.isEmpty)
        }
    }

    /// How far each recognizer has come from the video's start: k2 to
    /// where its captions are made, the whole video once they are done;
    /// each other one to the end of the furthest caption it has heard, the
    /// whole video once k2 is done and it has heard every caption. Each
    /// runs on over the silences between captions, which no one hears.
    nonisolated static func reached(
        captions: String, ready: Double, total: Double, own: [ClosedRange<Double>], others: [OtherHearing]
    ) -> [(label: String, seconds: Double)] {
        let done = captions == "done"
        let k2 = done ? max(total, ready) : max(ready, own.map(\.upperBound).max() ?? 0)
        return [("k2", k2)] + OtherHearing.shown.map { shown in
            let heard = others.filter { $0[keyPath: shown.text] != nil }
            let all = done && own.allSatisfy { caption in heard.contains { abs($0.start - caption.lowerBound) < 0.01 } }
            return (shown.label, all ? k2 : min(heard.map(\.end).max() ?? 0, k2))
        }
    }

    /// How far each recognizer's text has been translated from the video's
    /// start: to the end of the furthest caption with its translation, the
    /// whole video once k2 is done and every caption has one. k2's text
    /// comes translated, but for one the translator gave up on; the others'
    /// are translated after they are heard.
    nonisolated static func translated(
        captions: String, total: Double, own: [(range: ClosedRange<Double>, english: Bool)], others: [OtherHearing]
    ) -> [(label: String, seconds: Double)] {
        let done = captions == "done"
        let k2 = done && own.allSatisfy(\.english) ? total : own.filter(\.english).map(\.range.upperBound).max() ?? 0
        return [("k2", k2)] + OtherHearing.shown.map { shown in
            let translated = others.filter { $0[keyPath: shown.english] != nil }
            let all = done && own.allSatisfy { caption in
                translated.contains { abs($0.start - caption.range.lowerBound) < 0.01 }
            }
            return (shown.label, all ? total : translated.map(\.end).max() ?? 0)
        }
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
            if let picked {
                await open(picked, client: client)
                return
            }
            guard let probe = await video.probeMedia() else { return }
            if let unfetchable = probe.problem {
                problem = unfetchable
                return
            }
            guard !failedPages.contains(Self.failure(probe.page, step)) else { return }
            await startJob(for: probe, client: client)
            return
        }
        // Another video, while one is started or loaded: its job goes with
        // its captions, and the new one's starts at once, which takes from
        // the host's cache whatever was made of it before.
        if let picked {
            await leaveVideo()
            await open(picked, client: client)
            return
        }
        if Date().timeIntervalSince(lastProbe) >= Self.probeInterval {
            lastProbe = Date()
            if let probe = await video.probeMedia(), Self.isAnotherVideo(probe, than: current) {
                guard job?.id == current.id else { return }
                ActivityLog.tell("Another video: leaving the one before, and its captions")
                await leaveVideo()
                if let unfetchable = probe.problem {
                    problem = unfetchable
                    return
                }
                guard !failedPages.contains(Self.failure(probe.page, step)) else { return }
                await startJob(for: probe, client: client)
                return
            }
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
            forgetPicks()
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
                engine.add(status.lines, tabID: current.tabID, url: current.page)
            }
            updated.seenLines = status.count
            if let video = status.video, pickBook?.video != video {
                openPicks(of: video)
            }
            if let captions = status.captions, captions != updated.captions {
                updated.captions = captions
                if captions == "done" {
                    ActivityLog.tell("Step \(current.step.title): \(status.count) captions, the whole video")
                    await refreshProcessed()
                } else if captions.hasPrefix("failed") {
                    ActivityLog.tell("Step \(current.step.title): captions \(captions)")
                }
            }
            updated.fetched = max(status.fetched, 0)
            updated.ready = max(status.ready, 0)
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
            updated.othersReady = status.othersReady ?? true
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
            updated.running = status.running ?? []
            job = updated
            if status.state == "failed" {
                ActivityLog.tell("Step \(current.step.title) failed: \(status.error ?? "unknown")")
                problem = "The host couldn't fetch this video: \(status.error ?? "no reason given")"
                failedPages.insert(Self.failure(current.page, current.step))
                job = nil
            }
        } catch {
            print("step status: \(error.localizedDescription)")
        }
    }

    // MARK: The video kept for the phone

    /// Whether the host can be asked to keep the job's video for the
    /// phone: the step's captions have reached the end, the other
    /// recognizers' versions with them, and it is not fetching the video
    /// already.
    var canKeepForPhone: Bool {
        guard let job else { return false }
        return job.captions == "done" && job.othersReady && job.bundle != "running"
    }

    /// The captions are done and the host is still on the other versions.
    var isMakingVersions: Bool {
        guard let job else { return false }
        return job.captions == "done" && !job.othersReady
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

    /// Why the host would not keep the video, until read.
    var keepRefusal: String?

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
                keepRefusal = error.localizedDescription
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

    /// A processed video opened in Chrome and its job started: the host
    /// has its audio, so the page need not give a way to it.
    private func open(_ picked: ProcessedVideo, client: ASRClient) async {
        self.picked = nil
        guard let tab = await video.open(picked) else {
            ActivityLog.tell("Could not open the video in Chrome")
            problem = "Chrome could not open this video."
            isPaused = true
            return
        }
        await startJob(
            url: nil, page: picked.page, headers: [:], duration: picked.duration, tabID: tab.id, title: picked.title,
            client: client
        )
    }

    private func startJob(for probe: MediaProbe, client: ASRClient) async {
        var headers = ["User-Agent": probe.userAgent]
        if probe.mediaURL != nil { headers["Referer"] = probe.page }
        let title = video.tabs.first { $0.id == probe.tabID }?.title
            ?? video.pinned.flatMap { $0.id == probe.tabID ? $0.title : nil }
        await startJob(
            url: probe.mediaURL, page: probe.page, headers: headers, duration: probe.duration, tabID: probe.tabID,
            title: title, client: client
        )
    }

    private func startJob(
        url: String?, page: String, headers: [String: String], duration: Double?, tabID: Int, title: String?,
        client: ASRClient
    ) async {
        let step = step
        do {
            let id = try await client.startPrefetch(
                url: url, page: page, headers: headers, duration: duration, start: 0, step: step.rawValue, title: title
            )
            job = Job(id: id, tabID: tabID, page: page, step: step, duration: duration)
            problem = nil
            // The list shows this step's captions alone.
            engine.clear()
            if referencePage != page {
                referencePage = page
                reference = await client.reference(page: page)
                if !reference.isEmpty {
                    ActivityLog.tell("\(reference.count) official subtitle lines to set beside the captions")
                }
            }
            speech = []
            events = SoundEvents()
            words = []
            speakers = []
            others = []
            forgetPicks()
            selection = nil
            cursor = nil
            cursorArmed = false
            let length = duration.map { ", \(Self.clock($0)) long" } ?? ""
            ActivityLog.tell("Step \(step.title): fetching the whole video\(length), from its start")
            print("step \(step.rawValue) \(id): \(url ?? page)")
        } catch {
            ActivityLog.tell("Step \(step.title) could not start: \(error.localizedDescription)")
            problem = "The host couldn't start fetching this video: \(error.localizedDescription)"
            failedPages.insert(Self.failure(page, step))
        }
    }

    /// Whether `probe` is of another video than the job's: another tab, or
    /// another page in its tab.
    nonisolated static func isAnotherVideo(_ probe: MediaProbe, than job: Job) -> Bool {
        probe.tabID != job.tabID || probe.page != job.page
    }

    /// Stops the job and clears what it showed, its captions too, for
    /// another video to take its place.
    private func leaveVideo() async {
        await stopJob()
        engine.clear()
        problem = nil
        speech = []
        events = SoundEvents()
        words = []
        speakers = []
        others = []
        forgetPicks()
        selection = nil
        cursor = nil
        cursorArmed = false
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
                id: Self.otherID(of: caption.id, index), japanese: other.text, ruby: ruby, english: other.english,
                moment: caption.moment
            )
            return (other.label, sentence)
        }
    }

    /// The id the `index`th other recognizer's line under caption `id` is
    /// analysed by: below zero, apart from every caption's and each other's.
    nonisolated static func otherID(of id: Int, _ index: Int) -> Int {
        -(id * (OtherHearing.shown.count + 1) + index + 1)
    }

    // MARK: Picks

    /// The recognizer picked for `caption`.
    func pickedVersion(for caption: Caption) -> String? {
        caption.moment.flatMap { picks[PickClient.place(of: $0.seconds)] }
    }

    /// `name`'s text is the caption's from now on; nil takes the pick back,
    /// and all of them show again.
    func pick(_ name: String?, for caption: Caption) {
        guard let moment = caption.moment else { return }
        pickBook?.pick(name, at: PickClient.place(of: moment.seconds))
    }

    /// What the host holds now: back at the app, a pick may have been made
    /// on the phone.
    func refreshPicks() {
        guard let pickBook else { return }
        Task { await pickBook.refresh() }
    }

    private func openPicks(of video: String) {
        let book = PickBook(video: video, client: PickClient.over(host: engine.client?.baseURL, video: video))
        book.onChange = { [weak self] in self?.picks = $0 }
        pickBook = book
        picks = [:]
        Task { await book.refresh() }
    }

    private func forgetPicks() {
        pickBook = nil
        picks = [:]
    }

    /// The one of `others` heard over `caption`'s own stretch (the host
    /// tells each by the caption's times), as `others(for:)` gives it.
    nonisolated static func heard(_ others: [OtherHearing], over caption: Caption) -> [(label: String, text: String, english: String)] {
        guard let moment = caption.moment, let end = moment.end,
              let heard = others.first(where: { abs($0.start - moment.seconds) < 0.01 && abs($0.end - end) < 0.01 })
        else { return [] }
        return OtherHearing.shown.compactMap { shown in
            heard[keyPath: shown.text].map { (shown.label, $0, heard[keyPath: shown.english] ?? "") }
        }
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
