import Foundation
import Observation

/// The dev mode of captioning ahead: one step of the pipeline run on its
/// own, through the GPU host, over the whole of a Chrome video's audio,
/// for looking at what the step does. The host fetches the video from its
/// start and runs the step over everything it has, again as more arrives;
/// what it finds goes on a timeline in the Activity panel, where a stretch
/// can be picked out and heard from the fetched audio. No captions are
/// made, and the live listener goes on as it is.
@MainActor
@Observable
final class DevPipeline {
    /// The steps that can be run, in the pipeline's order.
    enum Step: String, CaseIterable, Identifiable {
        /// Silero finding where the speech is.
        case speech

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech: "1 · Speech (Silero)"
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
        var state = "running"
        /// Whether the host was told to hold the step.
        var paused = false
    }

    static let probeInterval: TimeInterval = 3
    static let pollInterval: TimeInterval = 1

    private(set) var job: Job?
    /// Where the speech is, as the step found it.
    private(set) var speech: [ClosedRange<Double>] = []
    /// Off at launch, like captioning ahead.
    private(set) var isPaused = true
    /// The stretch of the video picked out on the timeline.
    var selection: ClosedRange<Double>?
    /// Where the pointer was put on the timeline by a click, for playing
    /// from there.
    private(set) var cursor: Double?
    /// The pointer has been put somewhere since Space was last pressed, so
    /// the next press plays from there rather than pausing or resuming.
    private var cursorArmed = false
    let player = ClipPlayer()

    var step: Step {
        get { Step(rawValue: UserDefaults.standard.string(forKey: AppSettings.pipelineStep) ?? "") ?? .speech }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.pipelineStep) }
    }

    var isActive: Bool { job != nil }

    private let engine: CaptionEngine
    private let video: ChromeVideo
    private var loop: Task<Void, Never>?
    private var isTicking = false
    private var lastProbe = Date.distantPast
    /// Pages the host could not fetch or run the step over; not tried
    /// again until the mode is switched or the app relaunched.
    private var failedPages: Set<String> = []

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
    func show(job: Job, speech: [ClosedRange<Double>]) {
        self.job = job
        self.speech = speech
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
        guard engine.isRunning, engine.serverCanPrefetch, let client = engine.client, AppSettings.isDevPipeline else {
            await stopJob()
            return
        }
        guard let current = job else {
            guard !isPaused, Date().timeIntervalSince(lastProbe) >= Self.probeInterval else { return }
            lastProbe = Date()
            guard let probe = await video.probeMedia(), probe.isFetchable, !failedPages.contains(probe.page) else {
                return
            }
            await startJob(for: probe, client: client)
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
            let status = try await client.prefetchStatus(job: current.id, since: 0)
            guard var updated = job, updated.id == current.id else { return }
            updated.fetched = max(status.fetched, 0)
            updated.duration = status.duration ?? updated.duration
            updated.state = status.state
            let analysed = status.analysed ?? 0
            if analysed > updated.analysed || status.state == "done" && analysed != updated.analysed {
                let findings = try await client.stepFindings(job: current.id)
                guard job?.id == current.id else { return }
                speech = findings.stretches
                updated.analysed = findings.analysed
            }
            job = updated
            if status.state == "failed" {
                ActivityLog.tell("Step \(current.step.title) failed: \(status.error ?? "unknown")")
                failedPages.insert(current.page)
                job = nil
            }
        } catch {
            print("step status: \(error.localizedDescription)")
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
            speech = []
            selection = nil
            cursor = nil
            cursorArmed = false
            let length = probe.duration.map { ", \(Self.clock($0)) long" } ?? ""
            ActivityLog.tell("Step \(step.title): fetching the whole video\(length), from its start")
            print("step \(step.rawValue) \(id): \(probe.mediaURL ?? probe.page)")
        } catch {
            ActivityLog.tell("Step \(step.title) could not start: \(error.localizedDescription)")
            failedPages.insert(probe.page)
        }
    }

    private func stopJob() async {
        guard let job else { return }
        self.job = nil
        player.stop()
        await engine.client?.stopPrefetch(job: job.id)
    }

    /// "4:05.3", a place in the video to the tenth, as the host tells it.
    nonisolated static func clock(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        return String(format: "%d:%04.1f", tenths / 600, Double(tenths % 600) / 10)
    }
}
