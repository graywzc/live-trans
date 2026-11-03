import Foundation
import Observation

/// Captions a Chrome video ahead of the viewer from its own audio, through
/// the GPU host: the tab's video is probed for what it is made of, the host
/// fetches and transcribes all of it from its start, and the lines land
/// among the captions by where in the video they are, before the video gets
/// there. It runs from Start to Stop.
///
/// It also keeps track of where the video is, for the bar that shows it and
/// moves it.
@MainActor
@Observable
final class Prefetcher {
    struct Job: Equatable {
        let id: String
        let tabID: Int
        let page: String
        var duration: Double?
        /// Where in the video it began.
        var start = 0.0
        var fetched = 0.0
        /// Up to where the captions are in place.
        var ready = 0.0
        var state = "running"
        /// Lines taken so far.
        var seen = 0
        /// How many texts the other recognizers have given its captions.
        var others = 0
        /// What the host is busy with for it right now.
        var running: [String] = []
        /// Whether it is held on the host, by a Stop that kept the host.
        var paused = false
    }

    /// A stretch of the video captioned ahead.
    struct Stretch: Equatable {
        let from: Double
        let to: Double

        func holds(_ seconds: Double) -> Bool { from <= seconds && seconds < to }
    }

    /// How often the tab is probed for a change of video.
    static let probeInterval: TimeInterval = 3
    /// How often the job is asked for new lines and the video for its time.
    static let pollInterval: TimeInterval = 1

    private(set) var job: Job?
    /// Stretches of the job's video captioned by jobs before it.
    private(set) var finished: [Stretch] = []
    /// Where the video was when last asked, and when that was.
    private(set) var playhead: VideoMoment?
    private(set) var playheadAt = Date()
    /// The caption being spoken, for the list to light.
    private(set) var currentCaptionID: Int?
    /// The caption the video is at, between sentences too, for the list to
    /// keep to.
    private(set) var playingCaptionID: Int?
    /// Where the video is while no caption is being spoken, for the list to
    /// mark.
    private(set) var lull: Lull?

    var isActive: Bool { job != nil }
    /// Why the host could not fetch the video it was to caption ahead, for
    /// the viewer; nil while it can, or before it has tried.
    private(set) var problem: String?
    /// The captions heard again by the other recognizers, with their
    /// Chinese, once the host has made them all (see the server's
    /// PrefetchJob._finish).
    private(set) var others: [OtherHearing] = []
    @ObservationIgnored private var otherRuby: [String: [RubyToken]] = [:]
    /// The recognizer picked for each caption, by its id: in memory only,
    /// let go with the captions, where dev mode keeps its picks on the host.
    private(set) var picks: [Int: String] = [:]

    func pickedVersion(for caption: Caption) -> String? { picks[caption.id] }

    /// `name`'s text is the caption's while it is shown; nil takes the pick
    /// back, and all of them show again.
    func pick(_ name: String?, for caption: Caption) {
        picks[caption.id] = name
    }

    /// What the other recognizers heard over `caption`, as DevPipeline's
    /// `others(for:)` gives it in dev mode.
    func others(for caption: Caption) -> [(label: String, sentence: Caption)] {
        DevPipeline.heard(others, over: caption).enumerated().map { index, other in
            let ruby = otherRuby[other.text] ?? Furigana.annotate(other.text)
            otherRuby[other.text] = ruby
            return (other.label, Caption(
                id: DevPipeline.otherID(of: caption.id, index), japanese: other.text, ruby: ruby, english: other.english,
                moment: caption.moment
            ))
        }
    }

    /// Where the video is now, carried on from the last answer.
    var position: Double? {
        guard let playhead else { return nil }
        return playhead.playing ? playhead.advanced(by: Date().timeIntervalSince(playheadAt)).seconds : playhead.seconds
    }

    /// The stretches captioned ahead in the video the playhead is in.
    var captioned: [ClosedRange<Double>] {
        guard isOnFetchedVideo else { return [] }
        return stretches.map { $0.from...$0.to }
    }

    /// How far each recognizer has captioned the video at `playhead`, when
    /// it is the job's, as Default's bar shows it (DevPipeline.reached).
    func reached(on playhead: VideoMoment?) -> [(label: String, seconds: Double)] {
        guard let job, let playhead, playhead.tabID == job.tabID, playhead.url == job.page else { return [] }
        let own = engine.captions.compactMap { caption -> ClosedRange<Double>? in
            guard let moment = caption.moment, moment.tabID == job.tabID, moment.url == job.page, let end = moment.end
            else { return nil }
            return moment.seconds...max(end, moment.seconds)
        }
        return DevPipeline.reached(
            captions: job.state, ready: job.ready, total: max(job.duration ?? 0, job.fetched), own: own, others: others
        )
    }

    /// The audio the job holds, in the video the playhead is in.
    var fetchedAhead: ClosedRange<Double>? {
        guard isOnFetchedVideo, let job, job.fetched > job.start else { return nil }
        return job.start...job.fetched
    }

    private let engine: CaptionEngine
    private let video: ChromeVideo
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastProbe = Date.distantPast
    private var lastMedia: MediaProbe?
    private var isTicking = false
    /// Pages the host could not fetch; not tried again until the tab moves on.
    private var failedPages: Set<String> = []
    /// The tab and page `finished` is of.
    private var finishedIn: (tabID: Int, page: String)?
    /// When the bar last moved the video: an answer asked for before then
    /// is of where it was.
    private var scrubbedAt = Date.distantPast
    private var missedReadings = 0

    /// Whether the app is in dev mode: see `SidePanel.isDev`.
    var isDev: @MainActor () -> Bool = { false }

    init(engine: CaptionEngine, video: ChromeVideo) {
        self.engine = engine
        self.video = video
        engine.isPrefetched = { [weak self] moment in self?.covers(moment) ?? false }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let idle = self?.job == nil && self?.playhead == nil
                let interval = idle ? Self.probeInterval : Self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.followPlayhead()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Where the video is put in place without asking Chrome, for tests.
    func show(playhead: VideoMoment, at date: Date = Date()) {
        self.playhead = playhead
        playheadAt = date
    }

    /// The video was told to play or pause by Space: shown stopped where
    /// it is, or moving on from there, at once, rather than carried on (or
    /// held) until it is next asked, a second later at most, and then put
    /// back.
    func toggledByKey() {
        guard let playhead, let now = position else { return }
        self.playhead = VideoMoment(
            tabID: playhead.tabID, url: playhead.url, seconds: now, rate: playhead.rate,
            playing: !playhead.playing, duration: playhead.duration
        )
        playheadAt = Date()
        // A reading asked for before the key tells of before it.
        scrubbedAt = Date()
    }

    /// Moves the video to `seconds`, as the bar's thumb was dropped there.
    func scrub(to seconds: Double) {
        guard let playhead, video.send(.scrub(to: seconds)) else { return }
        // Shown there at once, without waiting to be told.
        self.playhead = VideoMoment(
            tabID: playhead.tabID, url: playhead.url, seconds: seconds, rate: playhead.rate,
            playing: playhead.playing, duration: playhead.duration
        )
        playheadAt = Date()
        scrubbedAt = Date()
        Task { await tick() }
    }

    /// The captions were cleared, and their picks go with them; the job
    /// goes on, as Default's does, with the captions still to come.
    func forget() {
        finished = []
        picks = [:]
    }

    /// Whether the video's captions at `moment` were fetched ahead.
    func covers(_ moment: VideoMoment) -> Bool {
        stretch(holding: moment) != nil
    }

    /// Every stretch captioned ahead: the job's own first, then those of
    /// the jobs before it.
    private var stretches: [Stretch] {
        guard let job, job.ready > job.start else { return finished }
        return [Stretch(from: job.start, to: job.ready)] + finished
    }

    private var isOnFetchedVideo: Bool {
        guard let playhead, let finishedIn else { return false }
        return playhead.tabID == finishedIn.tabID && playhead.url == finishedIn.page
    }

    private func stretch(holding moment: VideoMoment) -> Stretch? {
        guard let finishedIn, moment.tabID == finishedIn.tabID, moment.url == finishedIn.page else { return nil }
        return stretches.first { $0.holds(moment.seconds) }
    }

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        await readPlayhead()
        await manageJob()
    }

    /// Asks the video where it is, while there is a reason to know: captions
    /// are being made, or the video buttons have found a video.
    private func readPlayhead() async {
        guard engine.isRunning || video.controlled != nil else {
            playhead = nil
            return
        }
        let asked = Date()
        guard let moment = await video.moment(at: asked) else {
            // One answer missed is Chrome being busy; several, the video gone.
            missedReadings += 1
            if missedReadings >= 3 { playhead = nil }
            return
        }
        missedReadings = 0
        guard asked >= scrubbedAt else { return }
        playhead = moment
        playheadAt = asked
    }

    private func manageJob() async {
        // In dev mode the pipeline is run a step at a time, by DevPipeline.
        guard engine.isRunning, engine.serverCanPrefetch, let client = engine.client, !isDev() else {
            // Stopped with the host kept, as Default's Stop holds its job:
            // held there in memory, for Start to go on with.
            if !isDev(), let held = engine.heldClient {
                await holdJob(client: held)
            } else {
                await stopJob()
            }
            return
        }
        if Date().timeIntervalSince(lastProbe) >= Self.probeInterval {
            lastProbe = Date()
            if let probe = await video.probeMedia() {
                if let finishedIn, finishedIn.tabID != probe.tabID || finishedIn.page != probe.page {
                    // Another video: its captions take the place of the
                    // last one's, as in Default.
                    await stopJob()
                    engine.clear()
                    finished = []
                    self.finishedIn = nil
                    problem = nil
                }
                lastMedia = probe
                if let unfetchable = probe.problem { problem = unfetchable }
                if job == nil, probe.isFetchable, !failedPages.contains(probe.page) {
                    await startJob(for: probe, client: client)
                }
            }
        }
        guard let current = job else { return }
        if current.paused {
            do {
                try await client.setPrefetch(job: current.id, paused: false)
                if job?.id == current.id { job?.paused = false }
            } catch {
                print("prefetch resume: \(error.localizedDescription)")
                return
            }
        }
        do {
            let status = try await client.prefetchStatus(job: current.id, since: current.seen)
            guard var updated = job, updated.id == current.id else { return }
            updated.start = status.start ?? 0
            updated.fetched = status.fetched
            updated.ready = status.ready
            updated.duration = status.duration ?? updated.duration
            updated.state = status.state
            updated.seen = status.count
            updated.running = status.running ?? []
            if let count = status.others, count != updated.others,
               let findings = try? await client.stepFindings(job: current.id), job?.id == current.id {
                others = findings.others ?? []
                updated.others = count
            }
            job = updated
            // A line from a stretch an earlier job captioned is that job's
            // caption over again, and would take its place.
            let lines = status.lines.filter { line in
                guard let start = line.start else { return true }
                return !finished.contains { $0.holds(start) }
            }
            if !lines.isEmpty {
                engine.add(lines, tabID: current.tabID, url: current.page)
            }
            if status.state == "failed" {
                print("prefetch failed: \(status.error ?? "unknown")")
                problem = "The host couldn't fetch this video: \(status.error ?? "no reason given")"
                failedPages.insert(current.page)
                retire()
            }
        } catch {
            print("prefetch status: \(error.localizedDescription)")
        }
    }

    /// Starts a job for the probed video, from its start whatever the viewer
    /// is at: the host then has all of it to tell the speakers apart over.
    private func startJob(for probe: MediaProbe, client: ASRClient) async {
        retire()
        finishedIn = (probe.tabID, probe.page)
        let start = 0.0
        var headers = ["User-Agent": probe.userAgent]
        if probe.mediaURL != nil { headers["Referer"] = probe.page }
        do {
            let id = try await client.startPrefetch(
                url: probe.mediaURL, page: probe.page, headers: headers, duration: probe.duration, start: start
            )
            job = Job(
                id: id, tabID: probe.tabID, page: probe.page, duration: probe.duration,
                start: start, fetched: start, ready: start
            )
            print("prefetch \(id) from \(Int(start))s: \(probe.mediaURL ?? probe.page)")
            problem = nil
        } catch {
            print("prefetch could not start: \(error.localizedDescription)")
            problem = "The host couldn't start fetching this video: \(error.localizedDescription)"
            failedPages.insert(probe.page)
        }
    }

    /// Lets the job go, keeping what it captioned as a finished stretch.
    private func retire() {
        guard let job else { return }
        if job.ready > job.start {
            finished.insert(Stretch(from: job.start, to: job.ready), at: 0)
        }
        self.job = nil
    }

    /// Holds the job on the host: the captioning and all after it wait,
    /// the audio still fetched, until Start lets it go on.
    private func holdJob(client: ASRClient) async {
        guard let current = job, !current.paused else { return }
        do {
            try await client.setPrefetch(job: current.id, paused: true)
            if job?.id == current.id {
                job?.paused = true
                job?.running = []
            }
        } catch {
            print("prefetch pause: \(error.localizedDescription)")
        }
    }

    private func stopJob() async {
        guard let job else { return }
        retire()
        others = []
        picks = [:]
        currentCaptionID = nil
        playingCaptionID = nil
        lull = nil
        await (engine.client ?? engine.heldClient)?.stopPrefetch(job: job.id)
        // A host kept only for this job (on to Default while stopped, say)
        // is let go with it.
        if !engine.isRunning, engine.isHoldingHost { engine.stop() }
    }

    /// Marks the caption being played, which the list follows and
    /// highlights: over captions fetched ahead, or in dev mode over the
    /// step's captions, made by DevPipeline rather than a job here.
    func followPlayhead() {
        guard job != nil || !finished.isEmpty || isDev(), let playhead, let now = position else {
            if currentCaptionID != nil { currentCaptionID = nil }
            if playingCaptionID != nil { playingCaptionID = nil }
            if lull != nil { lull = nil }
            return
        }
        let id = Self.current(in: engine.captions, at: now, tabID: playhead.tabID, url: playhead.url)
        if id != currentCaptionID { currentCaptionID = id }
        let between = id == nil
            ? Self.lull(in: engine.captions, at: now, tabID: playhead.tabID, url: playhead.url) : nil
        if between != lull { lull = between }
        let near = id ?? between?.captionID
        if near != playingCaptionID { playingCaptionID = near }
    }

    /// The caption being spoken at `seconds` of the page's video, as
    /// `CaptionTiming` has it: the phone follows its video the same way.
    nonisolated static func current(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Int? {
        CaptionTiming.current(in: captions, at: seconds, tabID: tabID, url: url)
    }

    /// Where `seconds` of the page's video is among its captions when no
    /// sentence is being spoken, as `CaptionTiming` has it.
    nonisolated static func lull(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Lull? {
        CaptionTiming.lull(in: captions, at: seconds, tabID: tabID, url: url)
    }
}
