import Foundation
import Observation

/// Captions a Chrome video ahead of the viewer from its own audio, through
/// the GPU host: the tab's video is probed for what it is made of, the host
/// fetches and transcribes it in chunks, and the lines land among the
/// captions by where in the video they are, before the video gets there.
/// The live listener stands down over the stretch this covers. Nothing is
/// fetched until asked for, and it can be paused and taken up again.
@MainActor
@Observable
final class Prefetcher {
    struct Job: Equatable {
        let id: String
        let tabID: Int
        let page: String
        var duration: Double?
        var fetched = 0.0
        /// Up to where the captions are in place.
        var ready = 0.0
        var state = "running"
        /// Lines taken so far.
        var seen = 0
        /// Whether the host was told to hold its transcription.
        var paused = false
    }

    /// How often the tab is probed for a change of video.
    static let probeInterval: TimeInterval = 3
    /// How often the job is asked for new lines and the video for its time.
    static let pollInterval: TimeInterval = 1

    private(set) var job: Job?
    /// Where the video was when last asked, and when that was.
    private(set) var playhead: VideoMoment?
    private(set) var playheadAt = Date()
    /// The caption being spoken, for the list to light and follow.
    private(set) var currentCaptionID: Int?

    var isActive: Bool { job != nil }
    /// Off at launch: the video is only fetched ahead once asked to.
    private(set) var isPaused = true

    private let engine: CaptionEngine
    private let video: ChromeVideo
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var lastProbe = Date.distantPast
    private var isTicking = false
    /// Pages the host could not fetch; not tried again until the tab moves on.
    private var failedPages: Set<String> = []

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
                let interval = self?.job == nil ? Self.probeInterval : Self.pollInterval
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
    /// on from where it stopped.
    func toggle() {
        isPaused.toggle()
        lastProbe = .distantPast
        Task { await tick() }
    }

    /// Whether the video's captions at `moment` were fetched ahead.
    func covers(_ moment: VideoMoment) -> Bool {
        guard let job else { return false }
        return moment.tabID == job.tabID && moment.url == job.page && moment.seconds < job.ready
    }

    /// The caption's sentence heard again from the fetched audio, with the
    /// wider search and its context; what comes back corrects the caption.
    func rehear(_ caption: Caption) {
        guard let job, let moment = caption.moment, covers(moment), let end = moment.end,
              let client = engine.client
        else { return }
        Task {
            do {
                let lines = try await client.rehear(job: job.id, from: moment.seconds, to: end)
                engine.add(lines, tabID: job.tabID, url: job.page, heardAgain: true)
            } catch {
                print("rehear failed: \(error.localizedDescription)")
            }
        }
    }

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        guard engine.isRunning, engine.serverCanPrefetch, let client = engine.client,
              UserDefaults.standard.bool(forKey: AppSettings.prefetchVideo)
        else {
            await stopJob()
            return
        }
        if job == nil || Date().timeIntervalSince(lastProbe) >= Self.probeInterval {
            lastProbe = Date()
            if let probe = await video.probeMedia() {
                if let job, job.tabID != probe.tabID || job.page != probe.page {
                    await stopJob()
                }
                if job == nil, !isPaused, probe.isFetchable, !failedPages.contains(probe.page) {
                    await startJob(for: probe, client: client)
                }
            }
        }
        guard let current = job else { return }
        if current.paused != isPaused {
            do {
                try await client.setPrefetch(job: current.id, paused: isPaused)
                if job?.id == current.id { job?.paused = isPaused }
            } catch {
                // A host that cannot pause is stopped instead, and a job it
                // no longer has is started afresh.
                print("prefetch \(isPaused ? "pause" : "resume"): \(error.localizedDescription)")
                if isPaused { await stopJob() } else if job?.id == current.id { job = nil }
                return
            }
        }
        do {
            let status = try await client.prefetchStatus(job: current.id, since: current.seen)
            guard var updated = job, updated.id == current.id else { return }
            updated.fetched = status.fetched
            updated.ready = status.ready
            updated.duration = status.duration ?? updated.duration
            updated.state = status.state
            updated.seen = status.count
            job = updated
            if !status.lines.isEmpty {
                engine.add(status.lines, tabID: current.tabID, url: current.page, heardAgain: false)
            }
            if status.state == "failed" {
                print("prefetch failed: \(status.error ?? "unknown")")
                failedPages.insert(current.page)
                job = nil
            }
        } catch {
            print("prefetch status: \(error.localizedDescription)")
        }
        if let moment = await video.moment(at: Date()) {
            playhead = moment
            playheadAt = Date()
        }
    }

    private func startJob(for probe: MediaProbe, client: ASRClient) async {
        var headers = ["User-Agent": probe.userAgent]
        if probe.mediaURL != nil { headers["Referer"] = probe.page }
        do {
            let id = try await client.startPrefetch(
                url: probe.mediaURL, page: probe.page, headers: headers, duration: probe.duration
            )
            job = Job(id: id, tabID: probe.tabID, page: probe.page, duration: probe.duration)
            print("prefetch \(id): \(probe.mediaURL ?? probe.page)")
        } catch {
            print("prefetch could not start: \(error.localizedDescription)")
            failedPages.insert(probe.page)
        }
    }

    private func stopJob() async {
        guard let job else { return }
        self.job = nil
        currentCaptionID = nil
        await engine.client?.stopPrefetch(job: job.id)
    }

    private func followPlayhead() {
        guard job != nil, let playhead else {
            if currentCaptionID != nil { currentCaptionID = nil }
            return
        }
        let now = playhead.playing ? playhead.advanced(by: Date().timeIntervalSince(playheadAt)).seconds : playhead.seconds
        let id = Self.current(in: engine.captions, at: now, tabID: playhead.tabID, url: playhead.url)
        if id != currentCaptionID { currentCaptionID = id }
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
}
