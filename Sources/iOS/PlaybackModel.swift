import AVFoundation
import Observation

/// Whether the player can show the video yet.
enum VideoState: Equatable {
    case loading, ready, failed

    init(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay: self = .ready
        case .failed: self = .failed
        default: self = .loading
        }
    }
}

/// The video playing with its captions: which sentence it is on, a
/// sentence played again, and where it was left. The captions come from
/// the bundle's lines, with readings from the system's tokenizer, on a
/// video that stands in for the Mac's Chrome tab (see VideoMoment), so
/// the shared CaptionTiming answers for it as it does on the Mac.
@MainActor
@Observable
final class PlaybackModel {
    /// What the captions' moments name as their tab: the bundle is the
    /// one video here.
    static let tabID = 0

    let bundle: VideoBundle
    let captions: [Caption]
    let player: AVPlayer
    /// Where the video is, in seconds, as last observed.
    private(set) var time = 0.0
    /// The caption being spoken, and where the video is between sentences.
    private(set) var playingID: Int?
    private(set) var lull: Lull?
    private(set) var isPlaying = false
    /// The video's state: until it is ready its place shows what it is
    /// doing.
    private(set) var video = VideoState.loading

    @ObservationIgnored private var timeObserver: Any?
    private var stopObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var videoObservation: NSKeyValueObservation?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timings = PlaybackTimings()
    @ObservationIgnored private let timingsURL: URL?
    @ObservationIgnored private var frameWatch: FrameWatch?
    @ObservationIgnored private var reporting: Task<Void, Never>?
    @ObservationIgnored private var periodStart = ContinuousClock.now
    @ObservationIgnored private var tapStart: ContinuousClock.Instant?
    @ObservationIgnored private var remembered = 0.0

    /// The captions when they are ready already: making them takes a
    /// while, and the screen says how far it has got (see `captions(of:onLine:)`).
    init(
        bundle: VideoBundle, video: URL?, captions: [Caption]? = nil, timingsURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.timingsURL = timingsURL
        self.captions = captions ?? Self.captions(of: bundle)
        player = AVPlayer(playerItem: video.map { AVPlayerItem(url: $0) })
        player.actionAtItemEnd = .pause
    }

    /// The bundle's lines as captions: one id per line, in order, readings
    /// from the tokenizer, and each one's place in the video.
    nonisolated static func captions(of bundle: VideoBundle) -> [Caption] {
        bundle.lines.enumerated().map { index, line in caption(index, line, of: bundle) }
    }

    /// The same away from the main thread, where the tokenizer takes its
    /// second or so on a long video without holding the screen up; told
    /// each time how many lines are done.
    nonisolated static func captions(
        of bundle: VideoBundle, onLine: @escaping @MainActor (Int) -> Void
    ) async -> [Caption] {
        await Task.detached(priority: .userInitiated) {
            var captions: [Caption] = []
            captions.reserveCapacity(bundle.lines.count)
            for (index, line) in bundle.lines.enumerated() {
                captions.append(caption(index, line, of: bundle))
                await onLine(index + 1)
            }
            return captions
        }.value
    }

    private nonisolated static func caption(_ index: Int, _ line: VideoBundle.Line, of bundle: VideoBundle) -> Caption {
        var moment = VideoMoment(tabID: tabID, url: bundle.id, seconds: line.start)
        moment.end = line.end
        moment.duration = bundle.duration
        return Caption(id: index, japanese: line.ja, ruby: Furigana.annotate(line.ja), english: line.en, moment: moment)
    }

    // MARK: Following the video

    /// Starts following the player, and takes the video to where it was
    /// left. Sound plays with the ring switch off, like any video.
    func start() {
        guard timeObserver == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.observe(seconds: time.seconds) }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
        videoObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let state = VideoState(item.status)
            Task { @MainActor in self?.video = state }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in if playing { self?.tapLanded() } }
        }
        startTimings()
        if let kept = Self.restoredPosition(for: bundle, in: defaults) {
            seek(to: kept)
        }
    }

    /// Stops following, and remembers where the video was.
    func stop() {
        remember()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        clearStop()
        rateObservation = nil
        videoObservation = nil
        statusObservation = nil
        stopTimings()
        player.pause()
    }

    /// Where the video is now, as the player reports it: the lit caption,
    /// and the place between sentences, follow.
    func observe(seconds: Double) {
        time = seconds
        let lit = CaptionTiming.current(in: captions, at: seconds, tabID: Self.tabID, url: bundle.id)
        if isPlaying, let lit, lit != playingID, let start = captions[lit].moment?.seconds {
            timings.highlight(lateMs: (seconds - start) * 1000)
        }
        playingID = lit
        lull = playingID == nil ? CaptionTiming.lull(in: captions, at: seconds, tabID: Self.tabID, url: bundle.id) : nil
        // Playing on in the background, the app may be closed without a word.
        if abs(seconds - remembered) >= Self.rememberEvery { remember() }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
        remember()
    }

    /// A sentence played again is going to stop at its end.
    var stopsAtSentenceEnd: Bool { stopObserver != nil }

    /// Goes on from where the video is, past the end of a sentence played
    /// again.
    func continuePlaying() {
        clearStop()
        player.play()
    }

    /// Plays the sentence again from a little before it, and pauses a
    /// little after its end, as a click on a caption does on the Mac. The
    /// caption is lit at once, rather than when the video gets there.
    func replay(_ caption: Caption) {
        guard let moment = caption.moment else { return }
        let window = Self.replayWindow(of: moment)
        clearStop()
        tapStart = .now
        seek(to: window.from, tolerance: Self.replayTolerance)
        playingID = caption.id
        lull = nil
        if let to = window.to {
            let at = NSValue(time: CMTime(seconds: to, preferredTimescale: 600))
            stopObserver = player.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.player.pause()
                    self?.clearStop()
                }
            }
        }
        player.play()
    }

    /// From a little before the sentence to a little after its end; no
    /// end when the sentence has none.
    static func replayWindow(of moment: VideoMoment) -> (from: Double, to: Double?) {
        (max(moment.seconds - CaptionTiming.seekLead, 0), moment.end.map { $0 + CaptionTiming.seekTail })
    }

    /// How far from the asked place a sentence played again may start:
    /// inside the lead before it, and much quicker to answer a tap, the
    /// video's keyframes being seconds apart.
    static let replayTolerance = 0.3

    func seek(to seconds: Double, tolerance: Double = 0) {
        let seconds = max(seconds, 0)
        let tolerance = CMTime(seconds: tolerance, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) {
            [weak self] _ in
            // Already playing when tapped, the status does not change.
            Task { @MainActor in
                if self?.player.timeControlStatus == .playing { self?.tapLanded() }
            }
        }
        observe(seconds: seconds)
    }

    private func clearStop() {
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }

    // MARK: Timings

    /// How often a period's numbers go to the host.
    private static let reportEvery = Duration.seconds(30)

    private func startTimings() {
        guard let timingsURL else { return }
        periodStart = .now
        frameWatch = FrameWatch { [weak self] ms in
            MainActor.assumeIsolated { self?.timings.frame(ms: ms) }
        }
        reporting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reportEvery)
                guard !Task.isCancelled else { return }
                self?.sendTimings(to: timingsURL)
            }
        }
    }

    private func stopTimings() {
        frameWatch?.stop()
        frameWatch = nil
        reporting?.cancel()
        reporting = nil
        if let timingsURL { sendTimings(to: timingsURL) }
    }

    private func sendTimings(to url: URL) {
        let seconds = (ContinuousClock.now - periodStart) / .seconds(1)
        periodStart = .now
        guard !timings.isEmpty else { return }
        var report = timings.report(seconds: seconds)
        report.addConditions()
        Task { await report.send(to: url) }
    }

    /// The video is going, and a tap was waiting for it.
    private func tapLanded() {
        guard let tapStart else { return }
        self.tapStart = nil
        timings.tap(ms: (ContinuousClock.now - tapStart) / .milliseconds(1))
    }

    // MARK: Where it was left

    /// Kept per bundle, a convenience of this phone's, so the next opening
    /// goes on from there; not near either end, where starting over is
    /// what is wanted. Gone with the bundle.
    static func positionKey(for id: String) -> String { "position.\(id)" }

    static let rememberEvery = 5.0

    func remember() {
        remembered = time
        Self.remember(time, for: bundle, in: defaults)
    }

    static func remember(_ seconds: Double, for bundle: VideoBundle, in defaults: UserDefaults) {
        if seconds > 5, seconds < bundle.duration - 5 {
            defaults.set(seconds, forKey: positionKey(for: bundle.id))
        } else {
            defaults.removeObject(forKey: positionKey(for: bundle.id))
        }
    }

    static func restoredPosition(for bundle: VideoBundle, in defaults: UserDefaults) -> Double? {
        let seconds = defaults.double(forKey: positionKey(for: bundle.id))
        return seconds > 0 ? seconds : nil
    }

    static func forgetPosition(for id: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: positionKey(for: id))
    }
}
