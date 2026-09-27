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

    func testTheBarScalesToTheLongestOfWhatItKnows() {
        XCTAssertEqual(PrefetchBar.fraction(30, of: 120), 0.25)
        XCTAssertEqual(PrefetchBar.fraction(150, of: 120), 1)
        XCTAssertEqual(PrefetchBar.fraction(-1, of: 120), 0)
        XCTAssertEqual(PrefetchBar.fraction(1, of: 0), 0)
        XCTAssertEqual(
            PrefetchBar.summary(duration: 1445, fetched: 1085, ready: 860),
            "Captions ready to 14:20, audio fetched to 18:05 of 24:05"
        )
        XCTAssertEqual(PrefetchBar.summary(duration: nil, fetched: 65, ready: 0), "Captions ready to 0:00, audio fetched to 1:05")
    }

    func testStatusDecodes() throws {
        let json = #"{"state":"running","error":null,"duration":90.5,"fetched":60,"ready":35.8,"level":1200.5,"count":12,"lines":[{"ja":"あ","en":"a","start":35,"end":36}]}"#
        let status = try JSONDecoder().decode(PrefetchStatus.self, from: Data(json.utf8))
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
