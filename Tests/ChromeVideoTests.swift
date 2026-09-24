import JavaScriptCore
import WebKit
import XCTest
@testable import LiveTrans

final class ChromeVideoTests: XCTestCase {
    func testResultsNameTheTab() {
        XCTAssertEqual(
            ChromeScript.outcome(fromResult: "playing|567|Episode 12 | example.tv"),
            .controlled(ChromeScript.Tab(id: 567, title: "Episode 12 | example.tv", video: .playing), playing: true)
        )
        XCTAssertEqual(
            ChromeScript.outcome(fromResult: "paused|1173479941|Video"),
            .controlled(ChromeScript.Tab(id: 1_173_479_941, title: "Video", video: .paused), playing: false)
        )
        XCTAssertEqual(ChromeScript.outcome(fromResult: "none"), .noVideo)
        XCTAssertEqual(ChromeScript.outcome(fromResult: "gone"), .gone)
        XCTAssertEqual(ChromeScript.outcome(fromResult: "missing value|1|x"), .noVideo)
    }

    func testListingKeepsEveryTab() {
        let listing = [
            ["1", "1173479941", "paused", "https://example.tv/play/x", "Episode 12 | example"],
            ["1", "1173479942", "", "https://github.com/", "GitHub"],
            ["2", "12", "none", "https://example.com/shop", ""],
        ].map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
        XCTAssertEqual(ChromeScript.tabs(fromListing: listing), [
            .init(id: 1_173_479_941, window: 1, title: "Episode 12 | example", url: "https://example.tv/play/x", video: .paused, isChecked: true, isFront: true),
            .init(id: 1_173_479_942, window: 1, title: "GitHub", url: "https://github.com/", video: nil, isChecked: false, isFront: false),
            .init(id: 12, window: 2, title: "", url: "https://example.com/shop", video: nil, isChecked: true, isFront: true),
        ])
    }

    func testAutomaticPicksAFrontTabWithAVideo() {
        let background = ChromeScript.Tab(id: 1, title: "", video: .playing, isChecked: true, isFront: false)
        let pausedFront = ChromeScript.Tab(id: 2, title: "", video: .paused, isChecked: true, isFront: true)
        let playingFront = ChromeScript.Tab(id: 3, window: 2, title: "", video: .playing, isChecked: true, isFront: true)
        let noVideo = ChromeScript.Tab(id: 4, title: "", isChecked: true, isFront: true)
        let tabs = [background, pausedFront, playingFront, noVideo]
        XCTAssertEqual(ChromeScript.automaticTarget(in: tabs, remembered: nil), playingFront)
        XCTAssertEqual(ChromeScript.automaticTarget(in: tabs, remembered: 2), pausedFront)
        XCTAssertEqual(ChromeScript.automaticTarget(in: tabs, remembered: 1), playingFront)
        XCTAssertEqual(ChromeScript.automaticTarget(in: [pausedFront, noVideo], remembered: nil), pausedFront)
        XCTAssertNil(ChromeScript.automaticTarget(in: [background, noVideo], remembered: nil))
    }

    func testErrorsSayWhatToTurnOn() {
        XCTAssertEqual(
            ChromeScript.failure(number: 12, message: "Executing JavaScript through AppleScript is turned off.").message,
            "In Chrome, turn on View > Developer > Allow JavaScript from Apple Events."
        )
        XCTAssertTrue(ChromeScript.failure(number: -1743, message: "").message.contains("Automation"))
    }

    func testMomentWorksBackToWhenTheSentenceStarted() throws {
        let url = "https://example.tv/watch?v=a|b&t=1"
        let encoded = try XCTUnwrap(url.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let wall = Date(timeIntervalSince1970: 1_000)
        // Answered 0.4 s after the sentence started, at double speed.
        let moment = try XCTUnwrap(ChromeScript.moment(fromResult: "playing 100.8 1000.4 2 \(encoded)|567|Episode | 12", at: wall))
        XCTAssertEqual(moment.seconds, 100, accuracy: 0.001)
        XCTAssertEqual(moment, VideoMoment(tabID: 567, url: url, seconds: moment.seconds, rate: 2))
        // A paused video hasn't moved meanwhile.
        XCTAssertEqual(
            ChromeScript.moment(fromResult: "paused 100.8 1000.4 1 \(encoded)|567|Episode", at: wall)?.seconds,
            100.8
        )
        XCTAssertNil(ChromeScript.moment(fromResult: "none", at: wall))
        XCTAssertNil(ChromeScript.moment(fromResult: "gone", at: wall))
        XCTAssertEqual(ChromeScript.outcome(fromResult: "moved|567|Episode"), .moved)
    }

    func testJavaScriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        let moment = VideoMoment(tabID: 1, url: #"https://example.tv/"quoted"\path"#, seconds: 12.5)
        for script in [ChromeScript.momentJavaScript, ChromeScript.javaScript(ChromeScript.action(for: .seek(moment)))] {
            // Parsed but not run: there is no document here.
            context.exception = nil
            context.evaluateScript("(function () { return \(script); })")
            XCTAssertNil(context.exception, "\(context.exception!)\n\(script)")
        }
        XCTAssertTrue(ChromeScript.action(for: .seek(moment)).contains(#"!== "https:\/\/example.tv\/\"quoted\"\\path")"#))
        XCTAssertTrue(ChromeScript.action(for: .seek(moment)).contains("Math.max(12.0, 0)"))
    }

    func testScriptsCompile() throws {
        var sources = [
            ChromeScript.listSource, ChromeScript.probeSource(tab: 1_173_479_941),
            ChromeScript.source(running: ChromeScript.momentJavaScript, pinned: nil, preferring: 1_173_479_941),
        ]
        let moment = VideoMoment(tabID: 1_173_479_941, url: "https://example.tv/?a=\"b\"", seconds: 3)
        for command: ChromeVideo.Command in [.toggle, .skip(seconds: -5), .skip(seconds: 5), .seek(moment)] {
            sources.append(ChromeScript.source(for: command, pinned: nil, preferring: nil))
            sources.append(ChromeScript.source(for: command, pinned: nil, preferring: 1_173_479_941))
            sources.append(ChromeScript.source(for: command, pinned: 1_173_479_941, preferring: 1_173_479_941))
        }
        for source in sources {
            var error: NSDictionary?
            let script = try XCTUnwrap(NSAppleScript(source: source))
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])\n\(source)")
        }
    }

    func testJavaScriptSurvivesQuoting() {
        let quoted = ChromeScript.appleScriptString(#"say "hi" \ bye"#)
        XCTAssertEqual(quoted, #""say \"hi\" \\ bye""#)
    }
}

final class SpaceKeyTests: XCTestCase {
    @MainActor
    func testSpaceTypesOnlyWhereTextIsEdited() {
        let editable = NSTextView()
        XCTAssertTrue(SpaceKey.typesSpace(editable))
        let readOnly = NSTextView()
        readOnly.isEditable = false
        XCTAssertFalse(SpaceKey.typesSpace(readOnly))
        let web = WKWebView()
        let inside = NSView()
        web.addSubview(inside)
        XCTAssertTrue(SpaceKey.typesSpace(web))
        XCTAssertTrue(SpaceKey.typesSpace(inside))
        XCTAssertFalse(SpaceKey.typesSpace(NSWindow()))
        XCTAssertFalse(SpaceKey.typesSpace(nil))
    }
}

final class SentenceMomentTests: XCTestCase {
    func testLaterSentencesArePlacedByTheirShareOfTheText() {
        let start = VideoMoment(tabID: 1, url: "u", seconds: 60, rate: 1.5)
        let moments = CaptionEngine.moments(of: ["ああ", "いいいいいい"], from: start, spoken: 4)
        XCTAssertEqual(moments.map { $0?.seconds }, [60, 61.5])
        XCTAssertEqual(CaptionEngine.moments(of: ["ああ", "いい"], from: nil, spoken: 4), [nil, nil])
    }

    func testTimestampsReadLikeAPlayer() {
        XCTAssertEqual(CaptionRow.timestamp(0), "0:00")
        XCTAssertEqual(CaptionRow.timestamp(245.9), "4:05")
        XCTAssertEqual(CaptionRow.timestamp(3723), "1:02:03")
    }
}
