import Foundation
import Observation

/// Keeps track of where the Chrome video is, for the bar that shows it and
/// moves it, and for the caption list to follow: the caption being spoken,
/// or where the video is between two. The captions themselves are made
/// ahead of the video by DevPipeline, in either mode.
@MainActor
@Observable
final class Prefetcher {
    /// How often the video is asked for its time while there is one, and
    /// otherwise whether there is one.
    static let pollInterval: TimeInterval = 1
    static let probeInterval: TimeInterval = 3

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

    /// Where the video is now, carried on from the last answer.
    var position: Double? {
        guard let playhead else { return nil }
        return playhead.playing ? playhead.advanced(by: Date().timeIntervalSince(playheadAt)).seconds : playhead.seconds
    }

    private let engine: CaptionEngine
    private let video: ChromeVideo
    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var isReading = false
    /// When the bar last moved the video: an answer asked for before then
    /// is of where it was.
    private var scrubbedAt = Date.distantPast
    private var missedReadings = 0

    init(engine: CaptionEngine, video: ChromeVideo) {
        self.engine = engine
        self.video = video
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readPlayhead()
                let interval = self?.playhead == nil ? Self.probeInterval : Self.pollInterval
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
    }

    /// Asks the video where it is, while there is a reason to know: captions
    /// are being made, or the video buttons have found a video.
    private func readPlayhead() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
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

    /// Marks the caption being played, which the list follows and
    /// highlights.
    func followPlayhead() {
        guard let playhead, let now = position else {
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
