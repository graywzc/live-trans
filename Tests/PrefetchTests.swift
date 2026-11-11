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

    func testTheBarScalesToTheLongestOfWhatItKnows() {
        XCTAssertEqual(VideoBar.fraction(30, of: 120), 0.25)
        XCTAssertEqual(VideoBar.fraction(150, of: 120), 1)
        XCTAssertEqual(VideoBar.fraction(-1, of: 120), 0)
        XCTAssertEqual(VideoBar.fraction(1, of: 0), 0)
    }

    func testAPlaceOnTheBarIsAPlaceInTheVideo() {
        XCTAssertEqual(VideoBar.seconds(at: 100, in: 400, of: 1200), 300)
        XCTAssertEqual(VideoBar.seconds(at: -20, in: 400, of: 1200), 0)
        XCTAssertEqual(VideoBar.seconds(at: 900, in: 400, of: 1200), 1200)
        XCTAssertEqual(VideoBar.seconds(at: 10, in: 0, of: 1200), 0)
    }

    /// The caption being played is followed in either mode, over the
    /// captions DevPipeline makes.
    @MainActor
    func testThePlayingCaptionIsFollowed() {
        let engine = CaptionEngine()
        let prefetch = Prefetcher(engine: engine, video: ChromeVideo())
        engine.add([
            CaptionPair(ja: "あ", en: "a", start: 4, end: 6),
            CaptionPair(ja: "い", en: "i", start: 7, end: 9),
        ], tabID: 1, url: "https://example.com/v")
        prefetch.followPlayhead()
        XCTAssertNil(prefetch.currentCaptionID, "no video, nothing followed")
        prefetch.show(playhead: VideoMoment(tabID: 1, url: "https://example.com/v", seconds: 7.5))
        prefetch.followPlayhead()
        XCTAssertEqual(prefetch.currentCaptionID, engine.captions.last?.id)
        XCTAssertEqual(prefetch.playingCaptionID, engine.captions.last?.id)
    }

    /// The other recognizers' texts go under the caption with the same
    /// times, in the order shown, those not yet in left out.
    func testOtherRecognizersTextsGoToTheCaptionWithTheirTimes() throws {
        var moment = VideoMoment(tabID: 1, url: "p", seconds: 4.2)
        moment.end = 8
        let caption = Caption(id: 1, japanese: "あ", ruby: [], english: "a", moment: moment)
        let data = Data(#"{"analysed": 3, "speech": [], "others": [{"start": 0, "end": 4, "nemo": "甲"}, {"start": 4.2, "end": 8, "qwen": "乙", "nemo": "丙", "nemo_en": "丁"}]}"#.utf8)
        let others = try XCTUnwrap(JSONDecoder().decode(StepFindings.self, from: data).others)
        let heard = DevPipeline.heard(others, over: caption)
        XCTAssertEqual(heard.map(\.label), ["nemo", "qwen"])
        XCTAssertEqual(heard.map(\.text), ["丙", "乙"])
        XCTAssertEqual(heard.map(\.english), ["丁", ""], "each with its own translation, once in")
        XCTAssertTrue(DevPipeline.heard(Array(others.prefix(1)), over: caption).isEmpty)
        // A caption nemo's text was chosen for has k2's under it, and not nemo's again.
        var nemos = caption
        nemos.heardBy = "nemo"
        let k2 = try XCTUnwrap(JSONDecoder().decode(StepFindings.self, from: Data(
            #"{"analysed": 3, "speech": [], "others": [{"start": 4.2, "end": 8, "k2": "戊", "k2_en": "己", "qwen": "乙", "nemo": "丙"}]}"#.utf8
        )).others)
        let underNemo = DevPipeline.heard(k2, over: nemos)
        XCTAssertEqual(underNemo.map(\.label), ["k2", "qwen"])
        XCTAssertEqual(underNemo.map(\.english), ["己", ""])
        XCTAssertEqual(nemos.ownRecognizer, "nemo")
        XCTAssertEqual(caption.ownRecognizer, "k2", "a host that names none: k2's")
        // Analysed as captions of their own: ids no caption has, and none shared.
        // The last, past the others', is the typed text's.
        let ids = (1...50).flatMap { id in (0...OtherHearing.versions.count).map { DevPipeline.otherID(of: id, $0) } }
        XCTAssertTrue(ids.allSatisfy { $0 < 0 })
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The host's choice among the recognizers is a pick made for the person:
    /// shown alone until they pick another; picking the host's choice again
    /// keeps nothing.
    func testTheHostsChoiceIsAPickMadeForThePerson() {
        var caption = Caption(id: 1, japanese: "あ", ruby: [], english: "a")
        caption.heardBy = "nemo"
        XCTAssertEqual(caption.shownPick(nil, hasOthers: true), "nemo", "chosen for them")
        XCTAssertNil(caption.shownPick(nil, hasOthers: false), "nothing to choose from")
        XCTAssertNil(caption.pickToKeep(nil), "typed text taken back: the host's choice")
        XCTAssertEqual(caption.pickToKeep("qwen"), .recognizer("qwen"))
        XCTAssertEqual(caption.shownPick("qwen", hasOthers: true), "qwen")
        XCTAssertNil(caption.pickToKeep("nemo"), "the host's choice again keeps nothing")
        XCTAssertEqual(caption.pickToKeep(.typed("い")), .typed("い"))
        // From a host that chooses nothing, picks are as they were.
        let plain = Caption(id: 2, japanese: "あ", ruby: [], english: "a")
        XCTAssertNil(plain.shownPick(nil, hasOthers: true))
        XCTAssertNil(plain.pickToKeep(nil))
        XCTAssertEqual(plain.pickToKeep("k2"), .recognizer("k2"))
    }

    /// A click on the name shown alone shows every version in that row and
    /// sends nothing; only picking another from among them is a pick.
    func testShowingEveryVersionIsTheRowsOwnAndPicksNothing() {
        var shown = VersionsShown()
        var sent: [String?] = []
        XCTAssertEqual(shown.shown("nemo"), "nemo")
        shown.click(nil, picked: "nemo") { sent.append($0) }
        XCTAssertNil(shown.shown("nemo"), "all of them")
        XCTAssertEqual(sent, [], "nothing kept or sent")
        shown.click("nemo", picked: "nemo") { sent.append($0) }
        XCTAssertEqual(shown.shown("nemo"), "nemo", "the same one again: shown alone")
        XCTAssertEqual(sent, [])
        shown.click(nil, picked: "nemo") { sent.append($0) }
        shown.click("qwen", picked: "nemo") { sent.append($0) }
        XCTAssertEqual(sent, ["qwen"], "another: a pick")
        XCTAssertEqual(shown.shown("qwen"), "qwen")

        // Typed text taken back is dropped, and what was heard shows.
        shown.click(nil, picked: Pick.typedName) { sent.append($0) }
        XCTAssertEqual(sent, ["qwen", nil])
        XCTAssertNil(shown.shown("nemo"))
        shown.typed()
        XCTAssertEqual(shown.shown(Pick.typedName), Pick.typedName, "typed: it shows alone")
    }

    /// Incognito's picks are the captions' own, in memory, and go with them.
    @MainActor
    func testAPickInIncognitoLastsUntilTheCaptionsAreCleared() {
        let dev = DevPipeline(engine: CaptionEngine(), video: ChromeVideo())
        dev.keeps = { false }
        let first = caption(1, 1, 2), second = caption(2, 3, 4)
        dev.pick("nemo", for: first)
        XCTAssertEqual(dev.pickedVersion(for: first), "nemo")
        XCTAssertNil(dev.pickedVersion(for: second))
        dev.pick(nil, for: first)
        XCTAssertNil(dev.pickedVersion(for: first), "taken back")
        dev.pick("qwen", for: second)
        dev.captionsCleared()
        XCTAssertNil(dev.pickedVersion(for: second), "cleared with the captions")
    }

    /// Text typed in Incognito is the caption's in memory, as a pick is.
    @MainActor
    func testTypedTextInIncognitoIsPickedAndGoesWithTheCaptions() throws {
        let dev = DevPipeline(engine: CaptionEngine(), video: ChromeVideo())
        dev.keeps = { false }
        let first = caption(1, 1, 2)
        XCTAssertNil(dev.typed(for: first))
        dev.type("  雨が降ってきた \n", for: first)
        XCTAssertEqual(dev.pickedVersion(for: first), Pick.typedName)
        let typed = try XCTUnwrap(dev.typed(for: first))
        XCTAssertEqual(typed.japanese, "雨が降ってきた")
        XCTAssertEqual(typed.ruby.map(\.base).joined(), "雨が降ってきた")
        XCTAssertEqual(typed.english, "", "no host to translate it")
        XCTAssertEqual(typed.moment, first.moment)
        XCTAssertLessThan(typed.id, 0, "analysed apart from the caption")

        dev.pick("nemo", for: first)
        XCTAssertNil(dev.typed(for: first), "a pick takes its place")
        dev.type("晴れた", for: first)
        dev.type(" ", for: first)
        XCTAssertNil(dev.pickedVersion(for: first), "typed blank, it is dropped")
        dev.type("晴れた", for: first)
        dev.captionsCleared()
        XCTAssertNil(dev.typed(for: first))
    }

    /// Another tab, or another page in the job's tab, is another video,
    /// which Default goes over to; the same page again is not.
    func testAnotherTabOrPageIsAnotherVideo() {
        let job = DevPipeline.Job(id: "j", tabID: 1, page: "https://example.tv/watch?v=1", step: .speechMean)
        func probe(tab: Int, page: String) -> MediaProbe {
            MediaProbe(tabID: tab, page: page, duration: 600, source: nil, manifest: nil, encrypted: false, userAgent: "ua")
        }
        XCTAssertFalse(DevPipeline.isAnotherVideo(probe(tab: 1, page: "https://example.tv/watch?v=1"), than: job))
        XCTAssertTrue(DevPipeline.isAnotherVideo(probe(tab: 1, page: "https://example.tv/watch?v=2"), than: job))
        XCTAssertTrue(DevPipeline.isAnotherVideo(probe(tab: 2, page: "https://example.tv/watch?v=1"), than: job))
    }

    /// k2 reaches where its captions are made, the others the furthest
    /// caption each heard; once k2 is done, it and each other one that heard
    /// every caption reach the end.
    func testEachRecognizerReachesAsFarAsItHasCaptioned() {
        let own = [10.0...14, 20...25, 40...44]
        let others = [
            OtherHearing(start: 10, end: 14, nemo: "甲", qwen: "甲"),
            OtherHearing(start: 20, end: 25, nemo: "乙"),
        ]
        func reach(_ captions: String, ready: Double, _ others: [OtherHearing]) -> [String] {
            DevPipeline.reached(captions: captions, ready: ready, total: 600, own: own, others: others)
                .map { "\($0.label) \(Int($0.seconds))" }
        }
        XCTAssertEqual(reach("running", ready: 30, others), ["k2 44", "nemo 25", "qwen 14"], "k2 at least to its last caption")
        XCTAssertEqual(reach("running", ready: 50, []), ["k2 50", "nemo 0", "qwen 0"])
        XCTAssertEqual(reach("done", ready: 50, others), ["k2 600", "nemo 25", "qwen 14"])
        let heardAll = others + [OtherHearing(start: 40, end: 44, nemo: "丙")]
        XCTAssertEqual(reach("done", ready: 0, heardAll), ["k2 600", "nemo 600", "qwen 14"], "from the cache: done at once")
    }

    /// Each reaches the furthest caption with its translation; once k2 is
    /// done, the whole video for each with every caption translated.
    func testEachRecognizerIsTranslatedAsFarAsItsTranslationsGo() {
        let own: [(range: ClosedRange<Double>, english: Bool)] = [(10...14, true), (20...25, true), (40...44, false)]
        var others = [
            OtherHearing(start: 10, end: 14, nemo: "甲", qwen: "甲", nemoEnglish: "a", qwenEnglish: "a"),
            OtherHearing(start: 20, end: 25, nemo: "乙", qwen: "乙", nemoEnglish: ""),
            OtherHearing(start: 40, end: 44, nemo: "丙"),
        ]
        func reach(_ captions: String, _ own: [(range: ClosedRange<Double>, english: Bool)]) -> [String] {
            DevPipeline.translated(captions: captions, total: 600, own: own, others: others)
                .map { "\($0.label) \(Int($0.seconds))" }
        }
        // One the translator left in Japanese ("") counts as done with.
        XCTAssertEqual(reach("running", own), ["k2 25", "nemo 25", "qwen 14"])
        XCTAssertEqual(reach("done", own), ["k2 25", "nemo 25", "qwen 14"], "k2's last line has no translation")
        others[2].nemoEnglish = "c"
        let allEnglish = own.map { ($0.range, true) }
        XCTAssertEqual(reach("done", allEnglish), ["k2 600", "nemo 600", "qwen 14"])
        XCTAssertEqual(reach("running", allEnglish), ["k2 44", "nemo 44", "qwen 14"], "not the whole video until k2 is done")
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
        engine.add([CaptionPair(ja: "昨日は友達と", en: "", start: 10, end: 12)], tabID: 1, url: "u")
        engine.add([
            CaptionPair(ja: "昨日は友達と行きました", en: "Yesterday", start: 10, end: 12.5),
            CaptionPair(ja: "とても美味しかった", en: "Tasty", start: 13, end: 15),
            CaptionPair(ja: "置き場所なし", en: ""),
        ], tabID: 1, url: "u")
        XCTAssertEqual(engine.captions.map(\.japanese), ["昨日は友達と行きました", "とても美味しかった"])
        XCTAssertEqual(engine.captions.map(\.english), ["Yesterday", "Tasty"])
        XCTAssertEqual(engine.captions[1].moment?.end, 15)
    }
}
