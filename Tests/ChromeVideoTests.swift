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
        XCTAssertFalse(ChromeScript.action(for: .seek(moment)).contains("timeupdate"))
    }

    /// Playing one sentence pauses at its end, and only that once.
    func testPlayingASentenceStopsAtItsEnd() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const listeners = []; const log = [];
            const v = {
                currentTime: 0, paused: true, playbackRate: 1,
                play() { this.paused = false; log.push('play'); }, pause() { this.paused = true; log.push('pause'); },
                addEventListener(_, f) { listeners.push(f); }, removeEventListener(_, f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
            };
            const location = { href: 'u' };
            const tick = t => { v.currentTime = t; [...listeners].forEach(f => f()); };
            """)
        let moment = VideoMoment(tabID: 1, url: "u", seconds: 10, end: 14)
        let seek = "(() => { \(ChromeScript.action(for: .seek(moment))) })();"
        context.evaluateScript(seek)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("v.currentTime").toDouble(), 9.5)
        context.evaluateScript("tick(11); tick(13.5); tick(14.31);")
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "play,pause")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 0, "the stop is spent")
        // Seeking again while a stop is pending replaces it rather than stacking.
        context.evaluateScript(seek + seek)
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 1)
        // Going back before the sentence (a skip, an earlier sentence) drops it.
        context.evaluateScript("tick(3)")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "play,pause,play,play")
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

    @MainActor
    private func window(editing responder: NSView?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if let responder {
            responder.frame = window.contentView!.bounds
            window.contentView!.addSubview(responder)
            XCTAssertTrue(window.makeFirstResponder(responder))
        }
        addTeardownBlock { window.close() }
        return window
    }

    private func key(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
            keyCode: keyCode
        )!
    }

    private var space: NSEvent { key(" ", keyCode: 49) }
    private var controlC: NSEvent { key("c", keyCode: 8, modifiers: .control) }

    @MainActor
    func testSpaceTogglesTheVideoUnlessItWouldType() {
        var toggles = 0
        let idle = window(editing: nil)
        XCTAssertNil(SpaceKey.handle(space, in: idle, toggle: { toggles += 1 }))
        XCTAssertEqual(toggles, 1)

        let typing = window(editing: NSTextView())
        XCTAssertNotNil(SpaceKey.handle(space, in: typing, toggle: { toggles += 1 }))
        XCTAssertEqual(toggles, 1)
    }

    @MainActor
    func testControlCLeavesTheTextSoThatSpaceReachesTheVideo() {
        var toggles = 0
        let text = NSTextView()
        let window = window(editing: text)
        XCTAssertNil(SpaceKey.handle(controlC, in: window, toggle: { toggles += 1 }))
        XCTAssertFalse(window.firstResponder === text)
        XCTAssertNil(SpaceKey.handle(space, in: window, toggle: { toggles += 1 }))
        XCTAssertEqual(toggles, 1)
        // Plain C, and Control-C with nothing to leave, are someone else's.
        XCTAssertNotNil(SpaceKey.handle(key("c", keyCode: 8), in: window, toggle: { toggles += 1 }))
        XCTAssertNotNil(SpaceKey.handle(controlC, in: window, toggle: { toggles += 1 }))
        XCTAssertEqual(toggles, 1)
    }

    @MainActor
    func testControlCLeavesTheJishoPage() {
        let web = WKWebView()
        let window = window(editing: web)
        XCTAssertTrue(SpaceKey.typesSpace(window.firstResponder))
        XCTAssertNil(SpaceKey.handle(controlC, in: window, toggle: {}))
        XCTAssertFalse(SpaceKey.typesSpace(window.firstResponder))
    }
}

final class SentenceMomentTests: XCTestCase {
    func testLaterSentencesArePlacedByTheirShareOfTheText() {
        let start = VideoMoment(tabID: 1, url: "u", seconds: 60, rate: 1.5)
        let moments = CaptionEngine.moments(of: ["ああ", "いいいいいい"], from: start, spoken: 4)
        XCTAssertEqual(moments.map { $0?.seconds }, [60, 61.5])
        // Each ends where the next begins; the last where the speech did.
        XCTAssertEqual(moments.map { $0?.end }, [61.5, 66])
        XCTAssertEqual(CaptionEngine.moments(of: ["ああ", "いい"], from: nil, spoken: 4), [nil, nil])
    }

    func testTimestampsReadLikeAPlayer() {
        XCTAssertEqual(CaptionRow.timestamp(0), "0:00")
        XCTAssertEqual(CaptionRow.timestamp(245.9), "4:05")
        XCTAssertEqual(CaptionRow.timestamp(3723), "1:02:03")
    }
}
