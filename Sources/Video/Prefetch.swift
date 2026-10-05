import Foundation
import Observation

/// Where the video is among its captions while no sentence is being spoken.
struct Lull: Equatable {
    /// The caption it is next to.
    let captionID: Int
    /// After that caption, the last one spoken; before it when the video has
    /// not reached its first.
    let isAfter: Bool
    /// How far into the video, in whole seconds as the list shows it.
    let seconds: Int
}

/// Captions a Chrome video ahead of the viewer from its own audio, through
/// the GPU host: the tab's video is probed for what it is made of, the host
/// fetches and transcribes it in chunks from where the viewer is, and the
/// lines land among the captions by where in the video they are, before the
/// video gets there. When the viewer jumps to somewhere not captioned it
/// starts again from there, keeping what it has. The live listener stands
/// down over the stretches this covers. Nothing is fetched until asked for,
/// and it can be paused and taken up again.
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
        /// Whether the host was told to hold its transcription.
        var paused = false
        /// Whether the host can begin anywhere but the top. One that can't
        /// is left to run on when the viewer jumps.
        var seeks = true
    }

    /// A stretch of the video captioned ahead, and the job that holds its
    /// audio for hearing a sentence again.
    struct Stretch: Equatable {
        let job: String
        let from: Double
        let to: Double

        func holds(_ seconds: Double) -> Bool { from <= seconds && seconds < to }
    }

    /// How often the tab is probed for a change of video.
    static let probeInterval: TimeInterval = 3
    /// How often the job is asked for new lines and the video for its time.
    static let pollInterval: TimeInterval = 1
    /// How far the video may be from where it was expected before it counts
    /// as having jumped rather than stalled or caught up.
    nonisolated static let jumpTolerance = 2.0
    /// A viewer who lands this far past the captions is waited for: getting
    /// there takes less than starting again would.
    nonisolated static let reach = 120.0
    /// Starting at the viewer, it starts this far before, so the sentence
    /// being spoken is taken from its beginning.
    nonisolated static let lead = 3.0

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
    /// Off at launch: the video is only fetched ahead once asked to.
    private(set) var isPaused = true

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
    /// The video has jumped since the job was last looked at.
    private var jumped = false
    /// When the bar last moved the video: an answer asked for before then
    /// is of where it was.
    private var scrubbedAt = Date.distantPast
    private var missedReadings = 0
    /// The captions were cleared under the job, which starts over.
    private var restartForgetting = false

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

    /// Starts fetching ahead, or pauses it. Paused, the captions already
    /// fetched stay and the host stops transcribing; taken up again, it goes
    /// on from where it stopped, or from the viewer if they have moved away.
    func toggle() {
        isPaused.toggle()
        if !isPaused { jumped = true }
        lastProbe = .distantPast
        Task { await tick() }
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
        jumped = true
        Task { await tick() }
    }

    /// The captions were cleared, so nothing is covered any more.
    func forget() {
        finished = []
        if job != nil { restartForgetting = true }
        Task { await tick() }
    }

    /// Whether the video's captions at `moment` were fetched ahead.
    func covers(_ moment: VideoMoment) -> Bool {
        stretch(holding: moment) != nil
    }

    /// The caption's sentence heard again from the fetched audio, with the
    /// wider search and its context, and with the neighbours it follows on
    /// from, so a sentence cut in two is heard whole; what comes back
    /// corrects the captions.
    func rehear(_ caption: Caption) {
        guard let moment = caption.moment, let stretch = stretch(holding: moment),
              let window = CaptionEngine.rehearingStretch(for: caption, among: engine.captions),
              let client = engine.client
        else { return }
        let from = max(window.from, stretch.from), to = min(window.to, stretch.to)
        Task {
            do {
                let lines = try await client.rehear(job: stretch.job, from: from, to: to)
                engine.add(lines, tabID: moment.tabID, url: moment.url, heardAgain: true)
            } catch {
                print("rehear failed: \(error.localizedDescription)")
            }
        }
    }

    /// Hears the gap in the captions at `seconds` of a page's video again
    /// from the fetched audio, for a sentence that went unheard there, as
    /// the action to do so; what comes back goes among the captions. Only
    /// the speech in it is given to Whisper, which over music invents
    /// lines. Nil when the gap is too short to hold a sentence, or its
    /// audio was never fetched.
    func gapRehearing(at seconds: Double, tabID: Int, url: String) -> (() -> Void)? {
        guard let finishedIn, tabID == finishedIn.tabID, url == finishedIn.page, let client = engine.client,
              let gap = CaptionEngine.gapStretch(
                  at: seconds, among: engine.captions, tabID: tabID, url: url,
                  within: stretches.map { $0.from...$0.to }
              ),
              let stretch = stretches.first(where: { $0.holds((gap.from + gap.to) / 2) })
        else { return nil }
        let engine = self.engine
        return {
            Task {
                do {
                    let lines = try await client.rehear(job: stretch.job, from: gap.from, to: gap.to, speechOnly: true)
                    engine.add(lines, tabID: tabID, url: url, heardAgain: true)
                } catch {
                    print("gap rehear failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The gap under `caption`, before the one after it, heard again: the
    /// action, or nil when there is nothing there to hear.
    func gapRehearing(after caption: Caption) -> (() -> Void)? {
        guard let moment = caption.moment, let end = moment.end else { return nil }
        return gapRehearing(at: end, tabID: moment.tabID, url: moment.url)
    }

    /// The gap the video is in, heard again: the action, or nil when there
    /// is nothing there to hear.
    var lullRehearing: (() -> Void)? {
        guard let lull, let playhead else { return nil }
        return gapRehearing(at: Double(lull.seconds), tabID: playhead.tabID, url: playhead.url)
    }

    /// Every stretch captioned ahead: the job's own first, then those of
    /// the jobs before it.
    private var stretches: [Stretch] {
        guard let job, job.ready > job.start else { return finished }
        return [Stretch(job: job.id, from: job.start, to: job.ready)] + finished
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
        if let playhead, playhead.tabID == moment.tabID, playhead.url == moment.url {
            let expected = playhead.playing
                ? playhead.advanced(by: asked.timeIntervalSince(playheadAt)).seconds : playhead.seconds
            if abs(moment.seconds - expected) > Self.jumpTolerance { jumped = true }
        }
        playhead = moment
        playheadAt = asked
    }

    private func manageJob() async {
        guard engine.isRunning, engine.serverCanPrefetch, let client = engine.client,
              UserDefaults.standard.bool(forKey: AppSettings.prefetchVideo)
        else {
            await stopJob()
            return
        }
        if Date().timeIntervalSince(lastProbe) >= Self.probeInterval {
            lastProbe = Date()
            if let probe = await video.probeMedia() {
                if let finishedIn, finishedIn.tabID != probe.tabID || finishedIn.page != probe.page {
                    await stopJob()
                    finished = []
                    self.finishedIn = nil
                }
                lastMedia = probe
                if job == nil, !isPaused, probe.isFetchable, !failedPages.contains(probe.page) {
                    await startJob(for: probe, client: client)
                }
            }
        }
        guard let current = job else {
            jumped = false
            return
        }
        if restartForgetting {
            restartForgetting = false
            job = nil
            await client.stopPrefetch(job: current.id)
            lastProbe = .distantPast
            return
        }
        if current.paused != isPaused {
            do {
                try await client.setPrefetch(job: current.id, paused: isPaused)
                if job?.id == current.id { job?.paused = isPaused }
            } catch {
                // A host that cannot pause is stopped instead, and a job it
                // no longer has is started afresh.
                print("prefetch \(isPaused ? "pause" : "resume"): \(error.localizedDescription)")
                if isPaused { await stopJob() } else if job?.id == current.id { retire() }
                return
            }
        }
        do {
            let status = try await client.prefetchStatus(job: current.id, since: current.seen)
            guard var updated = job, updated.id == current.id else { return }
            updated.start = status.start ?? 0
            updated.seeks = status.start != nil
            updated.fetched = status.fetched
            updated.ready = status.ready
            updated.duration = status.duration ?? updated.duration
            updated.state = status.state
            updated.seen = status.count
            job = updated
            // A line from a stretch an earlier job captioned is that job's
            // caption over again, and would take its place.
            let lines = status.lines.filter { line in
                guard let start = line.start else { return true }
                return !finished.contains { $0.holds(start) }
            }
            if !lines.isEmpty {
                engine.add(lines, tabID: current.tabID, url: current.page, heardAgain: false)
            }
            if status.state == "failed" {
                print("prefetch failed: \(status.error ?? "unknown")")
                failedPages.insert(current.page)
                retire()
            }
        } catch {
            print("prefetch status: \(error.localizedDescription)")
        }
        let hasJumped = jumped
        jumped = false
        guard let current = job, current.seeks, !isPaused, let probe = lastMedia,
              probe.tabID == current.tabID, probe.page == current.page
        else { return }
        let viewer = hasJumped && isOnFetchedVideo ? position : nil
        if let target = Self.move(
            viewer: viewer, start: current.start, ready: current.ready,
            finished: finished.map { $0.from...$0.to }, duration: current.duration
        ) {
            await startJob(for: probe, client: client, at: target)
        }
    }

    /// Starts a job for the probed video where the viewer is, or at `target`,
    /// in place of the one running; nowhere when the rest is captioned.
    private func startJob(for probe: MediaProbe, client: ASRClient, at target: Double? = nil) async {
        let old = job
        retire()
        finishedIn = (probe.tabID, probe.page)
        let viewer = playhead.flatMap { $0.tabID == probe.tabID && $0.url == probe.page ? position : nil } ?? 0
        let start = target ?? Self.startPoint(viewer: viewer, covered: finished.map { $0.from...$0.to })
        if let duration = old?.duration ?? probe.duration, start >= duration - 1 {
            if let old { await client.stopPrefetch(job: old.id) }
            return
        }
        var headers = ["User-Agent": probe.userAgent]
        if probe.mediaURL != nil { headers["Referer"] = probe.page }
        do {
            let id = try await client.startPrefetch(
                url: probe.mediaURL, page: probe.page, headers: headers, duration: probe.duration, start: start
            )
            job = Job(
                id: id, tabID: probe.tabID, page: probe.page, duration: old?.duration ?? probe.duration,
                start: start, fetched: start, ready: start
            )
            print("prefetch \(id) from \(Int(start))s: \(probe.mediaURL ?? probe.page)")
        } catch {
            print("prefetch could not start: \(error.localizedDescription)")
            failedPages.insert(probe.page)
        }
    }

    /// Lets the job go, keeping what it captioned as a finished stretch.
    private func retire() {
        guard let job else { return }
        if job.ready > job.start {
            finished.insert(Stretch(job: job.id, from: job.start, to: job.ready), at: 0)
        }
        self.job = nil
    }

    private func stopJob() async {
        guard let job else { return }
        retire()
        currentCaptionID = nil
        playingCaptionID = nil
        lull = nil
        await engine.client?.stopPrefetch(job: job.id)
    }

    private func followPlayhead() {
        guard job != nil || !finished.isEmpty, let playhead, let now = position else {
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

    /// The first moment from `seconds` on that no stretch in `covered`
    /// holds: where captioning ahead has work to do for a viewer there.
    nonisolated static func frontier(from seconds: Double, covered: [ClosedRange<Double>]) -> Double {
        var at = seconds
        while let range = covered.first(where: { $0.lowerBound <= at && at < $0.upperBound }) {
            at = range.upperBound
        }
        return at
    }

    /// Where a job should begin for a viewer at `viewer`: a little before
    /// them where nothing is captioned, so the sentence being spoken is
    /// whole, else where the captions they are in run out.
    nonisolated static func startPoint(viewer: Double, covered: [ClosedRange<Double>]) -> Double {
        let ahead = frontier(from: viewer, covered: covered)
        guard ahead == viewer else { return ahead }
        return frontier(from: max(viewer - lead, 0), covered: covered)
    }

    /// Where the job should start again, if it should: past a stretch
    /// already captioned once it has run into one, or at a viewer who has
    /// jumped (`viewer`, nil when they haven't) to somewhere it isn't about
    /// to reach. The job has captioned `start` to `ready`, and jobs before
    /// it the stretches in `finished`. A viewer with nothing left to caption
    /// after them doesn't take the job from the stretch it is on.
    nonisolated static func move(
        viewer: Double?, start: Double, ready: Double, finished: [ClosedRange<Double>], duration: Double? = nil
    ) -> Double? {
        if let viewer {
            let covered = finished + (ready > start ? [start...ready] : [])
            let ahead = frontier(from: viewer, covered: covered)
            let isLeft = duration.map { ahead < $0 - 1 } ?? true
            if isLeft, ahead < start || ahead > ready + reach {
                return startPoint(viewer: viewer, covered: covered)
            }
        }
        let past = frontier(from: ready, covered: finished)
        return past > ready ? past : nil
    }

    /// The caption being spoken at `seconds` of the page's video: the one
    /// whose stretch holds it, else the last one that started before it,
    /// within a breath.
    nonisolated static func current(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Int? {
        var before: Caption?
        for caption in captions {
            guard let moment = caption.moment, moment.tabID == tabID, moment.url == url,
                  moment.seconds <= seconds
            else { continue }
            if let end = moment.end, seconds <= end { return caption.id }
            if before?.moment.map({ $0.seconds <= moment.seconds }) ?? true { before = caption }
        }
        guard let before, let moment = before.moment, seconds - (moment.end ?? moment.seconds) < 2 else { return nil }
        return before.id
    }

    /// Where `seconds` of the page's video is among its captions when no
    /// sentence is being spoken: after the last one that started before it,
    /// however long ago, else before the first one after it.
    nonisolated static func lull(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Lull? {
        var before: Caption?
        var after: Caption?
        for caption in captions {
            guard let moment = caption.moment, moment.tabID == tabID, moment.url == url else { continue }
            if moment.seconds <= seconds {
                if before?.moment.map({ $0.seconds <= moment.seconds }) ?? true { before = caption }
            } else if after?.moment.map({ moment.seconds < $0.seconds }) ?? true {
                after = caption
            }
        }
        guard let beside = before ?? after else { return nil }
        return Lull(captionID: beside.id, isAfter: before != nil, seconds: Int(max(seconds, 0)))
    }
}
