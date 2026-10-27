import XCTest
@testable import LiveTrans

final class PrefetchTests: XCTestCase {
    private func caption(_ id: Int, _ from: Double, _ to: Double, tab: Int = 1, url: String = "u") -> Caption {
        var moment = VideoMoment(tabID: tab, url: url, seconds: from)
        moment.end = to
        return Caption(id: id, japanese: "\(id)", ruby: [], english: "", moment: moment)
    }

    func testTheCurrentCaptionIsTheOneBeingSpoken() {
        let captions = [caption(0, 10, 12), caption(1, 12.5, 15), caption(2, 20, 22), caption(3, 12, 14, tab: 2)]
        XCTAssertEqual(Prefetcher.current(in: captions, at: 11, tabID: 1, url: "u"), 0)
        XCTAssertEqual(Prefetcher.current(in: captions, at: 13, tabID: 1, url: "u"), 1)
        // In the gap just after a sentence it is still that sentence ...
        XCTAssertEqual(Prefetcher.current(in: captions, at: 16, tabID: 1, url: "u"), 1)
        // ... but not once the pause has gone on.
        XCTAssertNil(Prefetcher.current(in: captions, at: 18, tabID: 1, url: "u"))
        XCTAssertNil(Prefetcher.current(in: captions, at: 5, tabID: 1, url: "u"))
        XCTAssertEqual(Prefetcher.current(in: captions, at: 13, tabID: 2, url: "u"), 3)
        XCTAssertNil(Prefetcher.current(in: captions, at: 13, tabID: 1, url: "v"))
    }

    func testBetweenSentencesTheVideoIsAfterTheLastOne() {
        let captions = [caption(0, 10, 12), caption(1, 12.5, 15), caption(2, 60, 62), caption(3, 30, 32, tab: 2)]
        // A long pause in the talk leaves it after the sentence before ...
        XCTAssertEqual(
            Prefetcher.lull(in: captions, at: 40.7, tabID: 1, url: "u"), Lull(captionID: 1, isAfter: true, seconds: 40)
        )
        XCTAssertEqual(
            Prefetcher.lull(in: captions, at: 300, tabID: 1, url: "u"), Lull(captionID: 2, isAfter: true, seconds: 300)
        )
        // ... and before anything is said, before the first one to come.
        XCTAssertEqual(
            Prefetcher.lull(in: captions, at: 5, tabID: 1, url: "u"), Lull(captionID: 0, isAfter: false, seconds: 5)
        )
        XCTAssertEqual(
            Prefetcher.lull(in: captions, at: 40, tabID: 2, url: "u"), Lull(captionID: 3, isAfter: true, seconds: 40)
        )
        XCTAssertNil(Prefetcher.lull(in: captions, at: 40, tabID: 1, url: "v"))
    }

    @MainActor
    func testSpaceStopsAndStartsTheVideoWhereItIsAtOnce() {
        let prefetcher = Prefetcher(engine: CaptionEngine(), video: ChromeVideo())
        // Playing from 10 s, two seconds ago.
        prefetcher.show(
            playhead: VideoMoment(tabID: 1, url: "u", seconds: 10, rate: 1, playing: true), at: Date().addingTimeInterval(-2)
        )
        prefetcher.toggledByKey()
        let stopped = prefetcher.position ?? 0
        XCTAssertEqual(stopped, 12, accuracy: 0.1, "stopped where it had got to, not where it was last read")
        XCTAssertEqual(prefetcher.playhead?.playing, false)
        XCTAssertEqual(prefetcher.position ?? 0, stopped, accuracy: 1e-9, "and held there")
        prefetcher.toggledByKey()
        XCTAssertEqual(prefetcher.playhead?.playing, true)
        XCTAssertEqual(prefetcher.position ?? 0, stopped, accuracy: 0.05, "going on from there")
    }

    @MainActor
    func testItStartsPausedAndTheToggleTakesItUp() {
        let prefetcher = Prefetcher(engine: CaptionEngine(), video: ChromeVideo())
        XCTAssertTrue(prefetcher.isPaused)
        XCTAssertNil(prefetcher.job)
        prefetcher.toggle()
        XCTAssertFalse(prefetcher.isPaused)
        prefetcher.toggle()
        XCTAssertTrue(prefetcher.isPaused)
    }

    func testTheBarScalesToTheLongestOfWhatItKnows() {
        XCTAssertEqual(VideoBar.fraction(30, of: 120), 0.25)
        XCTAssertEqual(VideoBar.fraction(150, of: 120), 1)
        XCTAssertEqual(VideoBar.fraction(-1, of: 120), 0)
        XCTAssertEqual(VideoBar.fraction(1, of: 0), 0)
        XCTAssertEqual(
            VideoBar.summary(duration: 1445, fetched: 1085, ready: 860),
            "Captions ready to 14:20, audio fetched to 18:05 of 24:05"
        )
        XCTAssertEqual(VideoBar.summary(duration: nil, fetched: 65, ready: 0), "Captions ready to 0:00, audio fetched to 1:05")
        // With nothing captioned ahead it says what the bar is for.
        XCTAssertEqual(VideoBar.summary(duration: 1200, fetched: nil, ready: nil), "Drag to move the Chrome video")
    }

    func testAPlaceOnTheBarIsAPlaceInTheVideo() {
        XCTAssertEqual(VideoBar.seconds(at: 100, in: 400, of: 1200), 300)
        XCTAssertEqual(VideoBar.seconds(at: -20, in: 400, of: 1200), 0)
        XCTAssertEqual(VideoBar.seconds(at: 900, in: 400, of: 1200), 1200)
        XCTAssertEqual(VideoBar.seconds(at: 10, in: 0, of: 1200), 0)
    }

    func testAJobBeginsWhereTheViewerIs() {
        // A little before them, for the sentence being spoken ...
        XCTAssertEqual(Prefetcher.startPoint(viewer: 600, covered: []), 597)
        XCTAssertEqual(Prefetcher.startPoint(viewer: 1, covered: []), 0)
        // ... but not back into what is captioned, and from inside a
        // captioned stretch where it runs out, through any that follow on.
        XCTAssertEqual(Prefetcher.startPoint(viewer: 600, covered: [300...598]), 598)
        XCTAssertEqual(Prefetcher.startPoint(viewer: 400, covered: [300...598]), 598)
        XCTAssertEqual(Prefetcher.startPoint(viewer: 400, covered: [598...900, 300...598]), 900)
        XCTAssertEqual(Prefetcher.frontier(from: 598, covered: [300...598]), 598)
    }

    func testAJumpToSomewhereUncaptionedMovesTheJob() {
        // Captioned 600-900 so far; nothing before.
        func move(_ viewer: Double?, finished: [ClosedRange<Double>] = [], duration: Double? = 3600) -> Double? {
            Prefetcher.move(viewer: viewer, start: 600, ready: 900, finished: finished, duration: duration)
        }
        // No jump, nothing to do, wherever the job is.
        XCTAssertNil(move(nil))
        // Within what it has, or just past it, the job is about to get there.
        XCTAssertNil(move(700))
        XCTAssertNil(move(900 + Prefetcher.reach))
        // Further on, or back before it, it starts again at the viewer.
        XCTAssertEqual(move(1500), 1497)
        XCTAssertEqual(move(200), 197)
        // Back into a stretch captioned earlier, it takes up where that ends,
        XCTAssertEqual(move(100, finished: [0...300]), 300)
        // which is nowhere new when that is where the job began.
        XCTAssertNil(move(100, finished: [0...600]))
        // Nothing is left after a viewer near the end: the job stays put.
        XCTAssertNil(move(3000, finished: [2000...3600]))
        XCTAssertEqual(move(3000, finished: [2000...3600], duration: nil), 3600)
    }

    func testAJobThatRunsIntoCaptionsGoesOnPastThem() {
        let finished: [ClosedRange<Double>] = [900...1500, 1500...1800]
        XCTAssertNil(Prefetcher.move(viewer: nil, start: 600, ready: 880, finished: finished))
        XCTAssertEqual(Prefetcher.move(viewer: nil, start: 600, ready: 905, finished: finished), 1800)
        // The viewer is in what it has: only the stretch ahead moves it.
        XCTAssertEqual(Prefetcher.move(viewer: 700, start: 600, ready: 905, finished: finished), 1800)
    }

    func testAStretchHoldsItsStartButNotItsEnd() {
        let stretch = Prefetcher.Stretch(job: "a", from: 10, to: 20)
        XCTAssertTrue(stretch.holds(10))
        XCTAssertTrue(stretch.holds(19.9))
        XCTAssertFalse(stretch.holds(20))
        XCTAssertFalse(stretch.holds(9.9))
    }

    /// In dev mode the step's captions are followed as production's are,
    /// with no job of the prefetcher's own; in production, with none, not.
    @MainActor
    func testThePlayingCaptionIsFollowedInDevMode() {
        let engine = CaptionEngine()
        let prefetch = Prefetcher(engine: engine, video: ChromeVideo())
        engine.add([
            CaptionPair(ja: "あ", en: "a", start: 4, end: 6),
            CaptionPair(ja: "い", en: "i", start: 7, end: 9),
        ], tabID: 1, url: "https://example.com/v", heardAgain: false)
        prefetch.show(playhead: VideoMoment(tabID: 1, url: "https://example.com/v", seconds: 7.5))
        prefetch.followPlayhead()
        XCTAssertNil(prefetch.currentCaptionID, "production with nothing fetched ahead follows nothing")
        var isDev = true
        prefetch.isDev = { isDev }
        prefetch.followPlayhead()
        XCTAssertEqual(prefetch.currentCaptionID, engine.captions.last?.id)
        XCTAssertEqual(prefetch.playingCaptionID, engine.captions.last?.id)
        isDev = false
        prefetch.followPlayhead()
        XCTAssertNil(prefetch.playingCaptionID)
    }

    /// The other recognizers' texts go under the caption with the same
    /// times, in the order shown, those not yet in left out.
    func testOtherRecognizersTextsGoToTheCaptionWithTheirTimes() throws {
        var moment = VideoMoment(tabID: 1, url: "p", seconds: 4.2)
        moment.end = 8
        let caption = Caption(id: 1, japanese: "あ", ruby: [], english: "a", moment: moment)
        let data = Data(#"{"analysed": 3, "speech": [], "others": [{"start": 0, "end": 4, "nemo": "甲"}, {"start": 4.2, "end": 8, "qwen": "乙", "nemo": "丙"}]}"#.utf8)
        let others = try XCTUnwrap(JSONDecoder().decode(StepFindings.self, from: data).others)
        let heard = DevPipeline.heard(others, over: caption)
        XCTAssertEqual(heard.map(\.label), ["nemo", "qwen"])
        XCTAssertEqual(heard.map(\.text), ["丙", "乙"])
        XCTAssertTrue(DevPipeline.heard(Array(others.prefix(1)), over: caption).isEmpty)
        // Analysed as captions of their own: ids no caption has, and none shared.
        let ids = (1...50).flatMap { id in (0..<OtherHearing.shown.count).map { DevPipeline.otherID(of: id, $0) } }
        XCTAssertTrue(ids.allSatisfy { $0 < 0 })
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Each official line goes to the caption it overlaps most; one too
    /// slight an overlap, or none, is left out; a caption may take several.
    func testOfficialSubtitlesAreMatchedToTheCaptionTheyOverlapMost() {
        func caption(_ id: Int, _ start: Double, _ end: Double) -> Caption {
            var moment = VideoMoment(tabID: 1, url: "p", seconds: start)
            moment.end = end
            return Caption(id: id, japanese: "あ", ruby: [], english: "a", moment: moment)
        }
        let captions = [caption(1, 0, 4), caption(2, 4.2, 8)]
        let lines = [
            ReferenceLine(start: 0.5, end: 2, text: "甲"),
            ReferenceLine(start: 2.2, end: 5, text: "乙"),  // 1.8 s with the first, 0.8 s with the second
            ReferenceLine(start: 5.5, end: 7, text: "丙"),
            ReferenceLine(start: 7.95, end: 9, text: "丁"),  // 0.05 s: too slight
            ReferenceLine(start: 20, end: 21, text: "戊"),
        ]
        XCTAssertEqual(DevPipeline.match(lines, to: captions), [1: ["甲", "乙"], 2: ["丙"]])
        let decoded = try? JSONDecoder().decode(ReferenceLine.self, from: Data(#"{"start":1.5,"end":3,"text":"今天"}"#.utf8))
        XCTAssertEqual(decoded, ReferenceLine(start: 1.5, end: 3, text: "今天"))
    }

    func testStatusDecodes() throws {
        let json = #"{"state":"running","error":null,"duration":90.5,"fetched":60,"ready":35.8,"level":1200.5,"count":12,"lines":[{"ja":"あ","en":"a","start":35,"end":36}]}"#
        let status = try JSONDecoder().decode(PrefetchStatus.self, from: Data(json.utf8))
        // A server from before jobs could begin anywhere doesn't say where.
        XCTAssertNil(status.start)
        let later = #"{"state":"running","start":597,"fetched":700,"ready":660.2,"count":0,"lines":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(PrefetchStatus.self, from: Data(later.utf8)).start, 597)
        // A dev job tells how its captions go; a server from before does not.
        XCTAssertNil(status.captions)
        let dev = #"{"state":"done","fetched":90,"ready":90,"count":3,"lines":[],"step":"speech","captions":"failed: timeout"}"#
        XCTAssertEqual(try JSONDecoder().decode(PrefetchStatus.self, from: Data(dev.utf8)).captions, "failed: timeout")
        XCTAssertEqual(status.state, "running")
        XCTAssertEqual(status.ready, 35.8)
        XCTAssertEqual(status.count, 12)
        XCTAssertEqual(status.lines, [CaptionPair(ja: "あ", en: "a", start: 35, end: 36)])
    }

    @MainActor
    func testFetchedLinesLandByVideoTimeAndReplaceWhatWasHeardLive() {
        let engine = CaptionEngine()
        // A line captioned live, roughly placed; the fetched ones cover it
        // and add the rest, and one without a place is left out.
        engine.add([CaptionPair(ja: "昨日は友達と", en: "", start: 10, end: 12)], tabID: 1, url: "u", heardAgain: false)
        engine.add([
            CaptionPair(ja: "昨日は友達と行きました", en: "Yesterday", start: 10, end: 12.5),
            CaptionPair(ja: "とても美味しかった", en: "Tasty", start: 13, end: 15),
            CaptionPair(ja: "置き場所なし", en: ""),
        ], tabID: 1, url: "u", heardAgain: false)
        XCTAssertEqual(engine.captions.map(\.japanese), ["昨日は友達と行きました", "とても美味しかった"])
        XCTAssertEqual(engine.captions.map(\.english), ["Yesterday", "Tasty"])
        XCTAssertEqual(engine.captions[1].moment?.end, 15)
    }

    @MainActor
    func testNothingIsCoveredBeforeAFetch() {
        let engine = CaptionEngine()
        let prefetcher = Prefetcher(engine: engine, video: ChromeVideo())
        XCTAssertFalse(prefetcher.covers(VideoMoment(tabID: 1, url: "u", seconds: 5)))
        XCTAssertEqual(engine.isPrefetched?(VideoMoment(tabID: 1, url: "u", seconds: 5)), false)
    }
}
