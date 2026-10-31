import AVFoundation
import Observation

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

    @ObservationIgnored private var timeObserver: Any?
    private var stopObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private let defaults: UserDefaults

    init(bundle: VideoBundle, video: URL?, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.defaults = defaults
        captions = Self.captions(of: bundle)
        player = AVPlayer(playerItem: video.map { AVPlayerItem(url: $0) })
        player.actionAtItemEnd = .pause
    }

    /// The bundle's lines as captions: one id per line, in order, readings
    /// from the tokenizer, and each one's place in the video.
    static func captions(of bundle: VideoBundle) -> [Caption] {
        bundle.lines.enumerated().map { index, line in
            var moment = VideoMoment(tabID: tabID, url: bundle.id, seconds: line.start)
            moment.end = line.end
            moment.duration = bundle.duration
            return Caption(id: index, japanese: line.ja, ruby: Furigana.annotate(line.ja), english: line.en, moment: moment)
        }
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
        player.pause()
    }

    /// Where the video is now, as the player reports it: the lit caption,
    /// and the place between sentences, follow.
    func observe(seconds: Double) {
        time = seconds
        playingID = CaptionTiming.current(in: captions, at: seconds, tabID: Self.tabID, url: bundle.id)
        lull = playingID == nil ? CaptionTiming.lull(in: captions, at: seconds, tabID: Self.tabID, url: bundle.id) : nil
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

    /// Whether there is anything for continuePlaying to do: not while the
    /// video is simply running.
    var canContinue: Bool { !isPlaying || stopsAtSentenceEnd }

    /// Goes on from where the video is, past the end of a sentence played
    /// again, whether it has stopped there already or is on its way.
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
        seek(to: window.from)
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

    func seek(to seconds: Double) {
        let seconds = max(seconds, 0)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        observe(seconds: seconds)
    }

    private func clearStop() {
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }

    // MARK: Where it was left

    /// Kept per bundle, a convenience of this phone's, so the next opening
    /// goes on from there; not near either end, where starting over is
    /// what is wanted. Gone with the bundle.
    static func positionKey(for id: String) -> String { "position.\(id)" }

    func remember() {
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
