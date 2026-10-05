import JavaScriptCore
import WebKit
import XCTest
@testable import LiveTrans

final class ChromeVideoTests: XCTestCase {
    func testResultsNameTheTab() {
        XCTAssertEqual(
            ChromeScript.outcome(fromResult: "playing|567|Video 12 | example.tv"),
            .controlled(ChromeScript.Tab(id: 567, title: "Video 12 | example.tv", video: .playing), playing: true)
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
            ["1", "1173479941", "paused", "https://example.tv/play/x", "Video 12 | example"],
            ["1", "1173479942", "", "https://github.com/", "GitHub"],
            ["2", "12", "none", "https://example.com/shop", ""],
        ].map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
        XCTAssertEqual(ChromeScript.tabs(fromListing: listing), [
            .init(id: 1_173_479_941, window: 1, title: "Video 12 | example", url: "https://example.tv/play/x", video: .paused, isChecked: true, isFront: true),
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
        let moment = try XCTUnwrap(ChromeScript.moment(fromResult: "playing 100.8 1000.4 2 600 \(encoded)|567|Video | 12", at: wall))
        XCTAssertEqual(moment.seconds, 100, accuracy: 0.001)
        XCTAssertEqual(
            moment, VideoMoment(tabID: 567, url: url, seconds: moment.seconds, rate: 2, playing: true, duration: 600)
        )
        // A paused video hasn't moved meanwhile.
        XCTAssertEqual(
            ChromeScript.moment(fromResult: "paused 100.8 1000.4 1 0 \(encoded)|567|Video", at: wall)?.seconds,
            100.8
        )
        // A video with no end has no duration.
        XCTAssertNil(ChromeScript.moment(fromResult: "paused 100.8 1000.4 1 0 \(encoded)|567|E", at: wall)?.duration)
        XCTAssertNil(ChromeScript.moment(fromResult: "none", at: wall))
        XCTAssertEqual(ChromeScript.moment(fromResult: "playing 100.8 1000.4 2 0 \(encoded)|567|E", at: wall)?.playing, true)
        XCTAssertEqual(ChromeScript.moment(fromResult: "paused 100.8 1000.4 1 0 \(encoded)|567|E", at: wall)?.playing, false)
        XCTAssertNil(ChromeScript.moment(fromResult: "gone", at: wall))
        XCTAssertEqual(ChromeScript.outcome(fromResult: "moved|567|Video"), .moved)
    }

    func testJavaScriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        let moment = VideoMoment(tabID: 1, url: #"https://example.tv/"quoted"\path"#, seconds: 12.5)
        for script in [
            ChromeScript.momentJavaScript, ChromeScript.mediaProbeJavaScript,
            ChromeScript.javaScript(ChromeScript.action(for: .seek(moment))),
            ChromeScript.javaScript(ChromeScript.action(for: .scrub(to: 754.25))),
        ] {
            // Parsed but not run: there is no document here.
            context.exception = nil
            context.evaluateScript("(function () { return \(script); })")
            XCTAssertNil(context.exception, "\(context.exception!)\n\(script)")
        }
        XCTAssertTrue(ChromeScript.action(for: .seek(moment)).contains(#"!== "https:\/\/example.tv\/\"quoted\"\\path")"#))
        XCTAssertTrue(ChromeScript.action(for: .seek(moment)).contains("Math.max(12.0, 0)"))
        XCTAssertFalse(ChromeScript.action(for: .seek(moment)).contains("timeupdate"))
    }

    /// A seek doesn't reach back into the sentence before: the lead stops
    /// where that one ends, when it ends short of this one.
    func testSeekLeadStopsAtTheSentenceBefore() {
        let url = "https://example.tv/watch"
        let sentence = VideoMoment(tabID: 1, url: url, seconds: 12.5, end: 14)
        let near = VideoMoment(tabID: 1, url: url, seconds: 11.8, end: 12.3)
        let far = VideoMoment(tabID: 1, url: url, seconds: 9, end: 10.5)
        let abutting = VideoMoment(tabID: 1, url: url, seconds: 11, end: 12.5)
        let elsewhere = VideoMoment(tabID: 2, url: url, seconds: 11.8, end: 12.4)
        let later = VideoMoment(tabID: 1, url: url, seconds: 14.2, end: 15)

        XCTAssertEqual(sentence.keptClear(of: [far, near, sentence, later, elsewhere]).floor, 12.3)
        XCTAssertEqual(sentence.keptClear(of: [far, sentence]).floor, 10.5)
        XCTAssertNil(sentence.keptClear(of: [abutting, sentence, later, elsewhere]).floor)

        let from: (VideoMoment) -> String = { moment in
            let action = ChromeScript.action(for: .seek(moment))
            let start = action.range(of: "const from = ")!.upperBound
            return String(action[start..<action[start...].firstIndex(of: ";")!])
        }
        XCTAssertEqual(from(sentence.keptClear(of: [far, near])), "Math.max(12.3, 0)")
        XCTAssertEqual(from(sentence.keptClear(of: [far])), "Math.max(12.0, 0)")
        XCTAssertEqual(from(sentence.keptClear(of: [abutting])), "Math.max(12.0, 0)")
    }

    /// A player in a frame of the page's own site is found, and the playlist
    /// is the one that frame loaded. Another site's frame is passed over.
    func testFindsAVideoInsideAFrame() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const doc = (videos, frames, view) => ({
                defaultView: view,
                querySelectorAll: q => q === 'video' ? videos : frames,
            });
            const entries = names => ({ performance: { getEntriesByType: () => names.map(name => ({ name })) } });
            const inner = entries(['https://example.tv/player.js', 'https://cdn.example.tv/a/index.m3u8?t=1']);
            const video = {
                readyState: 4, clientWidth: 640, clientHeight: 360, paused: false, duration: 600,
                currentSrc: 'blob:https://example.tv/1', mediaKeys: null,
            };
            video.ownerDocument = doc([video], [], inner);
            const foreign = { get contentDocument() { throw new Error('blocked'); } };
            const window = entries(['https://example.tv/page.css']);
            const performance = window.performance;
            const document = doc([], [{ contentDocument: null }, foreign, { contentDocument: video.ownerDocument }], window);
            const location = { href: 'https://example.tv/watch' };
            const navigator = { userAgent: 'Agent' };
            """)
        XCTAssertEqual(context.evaluateScript(ChromeScript.javaScript(""))?.toString(), "playing")
        let result = try XCTUnwrap(context.evaluateScript(ChromeScript.mediaProbeJavaScript)?.toString())
        XCTAssertNil(context.exception)
        let probe = try XCTUnwrap(ChromeScript.mediaProbe(fromResult: result + "|7|Title"))
        XCTAssertEqual(probe.manifest, "https://cdn.example.tv/a/index.m3u8?t=1")
        XCTAssertEqual(probe.page, "https://example.tv/watch")
        XCTAssertNil(probe.source)
        // With no video anywhere, the frames change nothing.
        context.evaluateScript("video.readyState = 0")
        XCTAssertEqual(context.evaluateScript(ChromeScript.javaScript(""))?.toString(), "none")
    }

    /// Playing one sentence pauses at its end, and only that once.
    func testPlayingASentenceStopsAtItsEnd() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const listeners = []; const log = [];
            const v = {
                currentTime: 0, paused: true, playbackRate: 1, seeking: false,
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
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause,play,pause")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 0, "the stop is spent")
        // Seeking again while a stop is pending replaces it rather than stacking.
        context.evaluateScript(seek + seek)
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 1)
        // Going back before the sentence (a skip, an earlier sentence) drops it.
        context.evaluateScript("tick(3)")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause,play,pause,pause,play,pause,play")
    }

    /// A seek the video has to load for is played once it has landed, not
    /// from where it was in the meantime.
    func testASlowSeekPlaysOnceLanded() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const log = []; let onSeeked = null;
            const v = {
                currentTime: 0, paused: false, playbackRate: 1, seeking: false,
                play() { this.paused = false; log.push('play'); }, pause() { this.paused = true; log.push('pause'); },
                addEventListener(name, f) { if (name === 'seeked') onSeeked = f; },
                removeEventListener() {},
            };
            Object.defineProperty(v, 'currentTime', { get() { return this._t; }, set(t) { this._t = t; this.seeking = true; } });
            const location = { href: 'u' };
            """)
        let moment = VideoMoment(tabID: 1, url: "u", seconds: 10, end: 14)
        let result = context.evaluateScript("(() => { \(ChromeScript.action(for: .seek(moment))) })();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toString(), "playing")
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause")
        context.evaluateScript("v.seeking = false; onSeeked();")
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause,play")
    }

    /// Dropping the bar's thumb moves the video and leaves it playing or
    /// paused as it was, without a sound from where it had been.
    func testScrubbingKeepsTheVideoPlayingOrPaused() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const listeners = []; const log = []; let onSeeked = null;
            const v = {
                _t: 30, paused: false, playbackRate: 1, seeking: false, duration: 600,
                play() { this.paused = false; log.push('play'); }, pause() { this.paused = true; log.push('pause'); },
                addEventListener(name, f) { if (name === 'seeked') { onSeeked = f; } else { listeners.push(f); } },
                removeEventListener(_, f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
            };
            Object.defineProperty(v, 'currentTime', { get() { return this._t; }, set(t) { this._t = t; this.seeking = true; } });
            const location = { href: 'u' };
            """)
        func scrub(to seconds: Double) -> String? {
            context.evaluateScript("(() => { \(ChromeScript.action(for: .scrub(to: seconds))) })();")?.toString()
        }
        XCTAssertEqual(scrub(to: 240), "playing")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("v.currentTime").toDouble(), 240)
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause")
        context.evaluateScript("v.seeking = false; onSeeked();")
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause,play")
        // A paused video stays paused, and the thumb can't leave the video.
        context.evaluateScript("v.pause(); log.length = 0; onSeeked = null;")
        XCTAssertEqual(scrub(to: 9_000), "paused")
        XCTAssertEqual(context.evaluateScript("v.currentTime").toDouble(), 600)
        XCTAssertEqual(scrub(to: -4), "paused")
        XCTAssertEqual(context.evaluateScript("v.currentTime").toDouble(), 0)
        XCTAssertEqual(context.evaluateScript("log.join()").toString(), "pause,pause")
        XCTAssertTrue(context.evaluateScript("onSeeked === null").toBool())
        // A sentence that was to stop at its end is let go, so landing past
        // it doesn't pause the video.
        let moment = VideoMoment(tabID: 1, url: "u", seconds: 10, end: 14)
        context.evaluateScript("(() => { \(ChromeScript.action(for: .seek(moment))) })(); v.seeking = false; onSeeked();")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 1)
        XCTAssertEqual(scrub(to: 300), "playing")
        XCTAssertEqual(context.evaluateScript("listeners.length").toInt32(), 0)
        XCTAssertTrue(context.evaluateScript("v.liveTransStop === null").toBool())
    }

    func testScriptsCompile() throws {
        var sources = [
            ChromeScript.listSource, ChromeScript.probeSource(tab: 1_173_479_941),
            ChromeScript.source(running: ChromeScript.momentJavaScript, pinned: nil, preferring: 1_173_479_941),
            ChromeScript.source(running: ChromeScript.mediaProbeJavaScript, pinned: 1_173_479_941, preferring: nil),
        ]
        let moment = VideoMoment(tabID: 1_173_479_941, url: "https://example.tv/?a=\"b\"", seconds: 3)
        for command: ChromeVideo.Command in [.toggle, .skip(seconds: -5), .skip(seconds: 5), .seek(moment), .scrub(to: 754.25)] {
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
        let window = TestScreen.window(width: 200, height: 100)
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
        let lines = [CaptionPair(ja: "ああ", en: ""), CaptionPair(ja: "いいいいいい", en: "")]
        let moments = CaptionEngine.moments(of: lines, from: start, spoken: 4)
        XCTAssertEqual(moments.map { $0?.seconds }, [60, 61.5])
        // Each ends where the next begins; the last where the speech did.
        XCTAssertEqual(moments.map { $0?.end }, [61.5, 66])
        XCTAssertEqual(CaptionEngine.moments(of: lines, from: nil, spoken: 4), [nil, nil])
    }

    /// The server heard where the words are, so the sentences are placed
    /// there: the audio began 0.3 s before the first speech, which is what
    /// the start moment marks.
    func testSentencesThatWerePlacedInTheAudioAreUsedAsIs() {
        let start = VideoMoment(tabID: 1, url: "u", seconds: 60, rate: 2)
        let lines = [
            CaptionPair(ja: "ああ", en: "", start: 0.3, end: 1.3),
            CaptionPair(ja: "いい", en: ""),
            CaptionPair(ja: "うう", en: "", start: 3.3, end: 4.1),
        ]
        let moments = CaptionEngine.moments(of: lines, from: start, spoken: 4, preRoll: 0.3)
        XCTAssertEqual(moments[0]?.seconds, 60)
        XCTAssertEqual(moments[0]?.end, 62)
        XCTAssertEqual(moments[2]?.seconds ?? 0, 66, accuracy: 0.001)
        XCTAssertEqual(moments[2]?.end ?? 0, 67.6, accuracy: 0.001)
        // The one the server couldn't place still goes by its share: two of
        // six characters into 4 s of speech, at double speed.
        XCTAssertEqual(moments[1]?.seconds ?? 0, 60 + 4.0 * 2 / 6 * 2, accuracy: 0.001)
    }

    func testTimestampsReadLikeAPlayer() {
        XCTAssertEqual(CaptionRow.timestamp(0), "0:00")
        XCTAssertEqual(CaptionRow.timestamp(245.9), "4:05")
        XCTAssertEqual(CaptionRow.timestamp(3723), "1:02:03")
    }
}

final class MediaProbeTests: XCTestCase {
    private func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    func testProbeReadsWhatTheVideoIsMadeOf() throws {
        let page = "https://example.tv/watch?v=1&t=2"
        let manifest = "https://cdn.example.tv/v/1/index.m3u8?token=a|b"
        let result = "clear 600.5  \(encoded(manifest)) \(encoded(page)) \(encoded("Mozilla/5.0 (X)"))|567|Video | 12"
        let probe = try XCTUnwrap(ChromeScript.mediaProbe(fromResult: result))
        XCTAssertEqual(probe, MediaProbe(
            tabID: 567, page: page, duration: 600.5, source: nil, manifest: manifest, encrypted: false,
            userAgent: "Mozilla/5.0 (X)"
        ))
        XCTAssertEqual(probe.mediaURL, manifest)
        XCTAssertTrue(probe.isFetchable)
    }

    func testAFileSourceComesFirstAndDRMCannotBeFetched() throws {
        let file = "https://example.tv/a.mp4"
        let clear = try XCTUnwrap(ChromeScript.mediaProbe(
            fromResult: "clear 0 \(encoded(file)) \(encoded("https://x/m.mpd")) \(encoded("https://x/")) ua|1|T"
        ))
        XCTAssertEqual(clear.mediaURL, file)
        XCTAssertNil(clear.duration, "an unknown duration is nil, not zero")
        let drm = try XCTUnwrap(ChromeScript.mediaProbe(fromResult: "drm 100   \(encoded("https://x/")) ua|1|T"))
        XCTAssertTrue(drm.encrypted)
        XCTAssertFalse(drm.isFetchable)
        // A player that assembles its own stream, on a page the host can ask about.
        let page = try XCTUnwrap(ChromeScript.mediaProbe(fromResult: "clear 100   \(encoded("https://x/")) ua|1|T"))
        XCTAssertNil(page.mediaURL)
        XCTAssertTrue(page.isFetchable)
        XCTAssertNil(ChromeScript.mediaProbe(fromResult: "none"))
        XCTAssertNil(ChromeScript.mediaProbe(fromResult: "gone"))
    }
}
