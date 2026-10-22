import SwiftUI
import XCTest
@testable import LiveTrans

@MainActor
final class ActivityLogTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_000_000)

    private func answer(boot: String, next: Int, _ events: [(Int, Double, String)]) -> HostEvents {
        HostEvents(
            boot: boot, next: next,
            events: events.map { .init(seq: $0.0, at: noon.timeIntervalSince1970 + $0.1, text: $0.2) }
        )
    }

    func testALineGoesWhereItsTimeIs() {
        let log = ActivityLog()
        log.isEnabled = true
        log.record("first", at: noon)
        log.record("third", at: noon.addingTimeInterval(2))
        // The server's line of a second ago, arriving after the Mac's of now.
        log.record("second", from: .host, at: noon.addingTimeInterval(1))
        XCTAssertEqual(log.entries.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(log.entries.map(\.machine), [.mac, .host, .mac])
        XCTAssertEqual(Set(log.entries.map(\.id)).count, 3)
    }

    func testLinesOfTheSameMomentKeepTheirOrder() {
        let log = ActivityLog()
        log.isEnabled = true
        log.record("one", at: noon)
        log.record("two", at: noon)
        XCTAssertEqual(log.entries.map(\.text), ["one", "two"])
    }

    func testTheOldestLinesAreLetGo() {
        let log = ActivityLog()
        log.isEnabled = true
        for n in 0..<(ActivityLog.kept + 5) {
            log.record("line \(n)", at: noon.addingTimeInterval(Double(n)))
        }
        XCTAssertEqual(log.entries.count, ActivityLog.kept)
        XCTAssertEqual(log.entries.first?.text, "line 5")
    }

    func testTheServersLinesAreTakenFromWhereItLeftOff() {
        let log = ActivityLog()
        log.isEnabled = true
        log.take(answer(boot: "a", next: 2, [(1, 0, "loading"), (2, 1, "listening")]))
        XCTAssertEqual(log.since, 2)
        log.take(answer(boot: "a", next: 3, [(3, 2, "job started")]))
        XCTAssertEqual(log.entries.map(\.text), ["loading", "listening", "job started"])
        XCTAssertEqual(log.since, 3)
    }

    func testARestartedServerIsAskedFromTheTop() {
        let log = ActivityLog()
        log.isEnabled = true
        log.take(answer(boot: "a", next: 40, [(40, 0, "idle, shutting down")]))
        // Started again, it has two lines, and none past the fortieth.
        log.take(answer(boot: "b", next: 2, []))
        XCTAssertEqual(log.since, 0)
        log.take(answer(boot: "b", next: 2, [(1, 5, "loading"), (2, 6, "listening")]))
        XCTAssertEqual(log.entries.map(\.text), ["idle, shutting down", "loading", "listening"])
        XCTAssertEqual(log.since, 2)
    }

    func testTheServersAnswerIsRead() throws {
        let json = #"{"boot": "1a2b3c4d", "next": 7, "events": [{"seq": 7, "at": 1000000.5, "text": "listening"}]}"#
        let answer = try JSONDecoder().decode(HostEvents.self, from: Data(json.utf8))
        XCTAssertEqual(answer, HostEvents(boot: "1a2b3c4d", next: 7, events: [.init(seq: 7, at: 1_000_000.5, text: "listening")]))
    }

    /// Production keeps no account of how the captions come about.
    func testNothingIsListedOutsideDevMode() {
        let log = ActivityLog()
        log.record("one", at: noon)
        log.take(answer(boot: "a", next: 2, [(1, 0, "loading"), (2, 1, "listening")]))
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.since, 0, "the server's lines are not counted as read")
    }

    func testLeavingDevModeLetsTheListGo() {
        let log = ActivityLog()
        log.isEnabled = true
        log.record("one", at: noon)
        log.isEnabled = false
        XCTAssertTrue(log.entries.isEmpty)
        log.isEnabled = true
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testClearingEmptiesTheList() {
        let log = ActivityLog()
        log.isEnabled = true
        log.record("one", at: noon)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}

@MainActor
final class ActivityViewTests: XCTestCase {
    func testTheServerIsCalledByItsHost() {
        XCTAssertEqual(ActivityView.hostName(sshHost: "me@gpubox "), "gpubox")
        XCTAssertEqual(ActivityView.hostName(sshHost: "gpubox"), "gpubox")
        XCTAssertEqual(ActivityView.hostName(sshHost: ""), "GPU")
    }

    func testWhatTheMacIsDoing() {
        XCTAssertEqual(ActivityView.macStatus(.idle, isSpeaking: false, awaited: 0), "Not captioning")
        XCTAssertEqual(ActivityView.macStatus(.listening("GPU"), isSpeaking: false, awaited: 0), "Listening")
        XCTAssertEqual(
            ActivityView.macStatus(.listening("GPU"), isSpeaking: true, awaited: 1),
            "Hearing speech · 1 utterance awaiting its captions"
        )
        XCTAssertEqual(
            ActivityView.macStatus(.reconnecting, isSpeaking: false, awaited: 3),
            "Listening · 3 utterances awaiting their captions"
        )
        XCTAssertEqual(ActivityView.macStatus(.failed("No input"), isSpeaking: false, awaited: 0), "No input")
    }

    func testWhatTheServerIsDoing() {
        XCTAssertEqual(ActivityView.hostStatus(.idle, job: nil), "Not in use")
        XCTAssertEqual(ActivityView.hostStatus(.reconnecting, job: nil), "Not answering, being restarted")
        XCTAssertEqual(ActivityView.hostStatus(.listening("GPU · large-v3"), job: nil), "GPU · large-v3")
        var job = Prefetcher.Job(id: "1a2b3c4d5e6f", tabID: 1, page: "https://example.com/watch", duration: 1440)
        job.fetched = 412
        job.ready = 380
        XCTAssertEqual(
            ActivityView.hostStatus(.listening("GPU · large-v3"), job: job),
            "GPU · large-v3\nJob 1a2b3c running · fetched to 6:52 · captioned to 6:20 of 24:00"
        )
        job.paused = true
        job.duration = nil
        XCTAssertEqual(ActivityView.jobStatus(job), "Job 1a2b3c paused · fetched to 6:52 · captioned to 6:20")
    }

    /// Dev mode in the real window, its activity unfolded under the
    /// timeline, with lines from both machines in it.
    func testTheActivityListsBothMachines() throws {
        let panel = SidePanel()
        panel.isDev = true
        let shown = UserDefaults.standard.object(forKey: AppSettings.activityLogShown)
        UserDefaults.standard.set(true, forKey: AppSettings.activityLogShown)
        defer { UserDefaults.standard.set(shown, forKey: AppSettings.activityLogShown) }
        let log = ActivityLog()
        log.isEnabled = true
        let start = Date(timeIntervalSince1970: 1_000_000)
        log.record("status: connecting", at: start)
        log.record("loading ASR on cuda", from: .host, at: start.addingTimeInterval(1))
        log.record("utterance 0: 3.2 s, noise floor 40, threshold 120", at: start.addingTimeInterval(9))
        log.record("live: 3.2s, 2 lines in 0.8s", from: .host, at: start.addingTimeInterval(10))
        log.record("utterance 0: 2 lines in 0.9 s", at: start.addingTimeInterval(10.1))

        let engine = CaptionEngine()
        let video = ChromeVideo()
        let root = ContentView()
            .environment(engine)
            .environment(JishoBrowser())
            .environment(SentenceAnalyzer(makeClient: { nil }))
            .environment(panel)
            .environment(video)
            .environment(Prefetcher(engine: engine, video: video))
            .environment(DevPipeline(engine: engine, video: video))
            .environment(log)
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }

        let view = try XCTUnwrap(window.contentView)
        func controls(_ v: NSView) -> [NSControl] {
            ((v as? NSControl).map { [$0] } ?? []) + v.subviews.flatMap(controls)
        }
        let pickers = try XCTUnwrap(
            TestScreen.wait { Optional(controls(view).compactMap { $0 as? NSSegmentedControl }).flatMap { $0.count == 2 ? $0 : nil } },
            "no mode switch and panel tabs"
        )
        // The header's Production | Dev, on Dev; the panel's Jisho | Analysis.
        XCTAssertEqual(pickers.map(\.segmentCount), [2, 2])
        XCTAssertEqual(pickers.map(\.selectedSegment), [1, 0])

        snapshot(view, "dev-activity")
    }

    /// Dev mode puts the step's timeline under the captions, with a line
    /// above it to size it by; the side panel keeps Jisho and the analysis.
    func testDevModeShowsTheStepsTimelineUnderTheCaptions() throws {
        let panel = SidePanel()
        panel.isDev = true
        let engine = CaptionEngine()
        let video = ChromeVideo()
        let dev = DevPipeline(engine: engine, video: video)
        var job = DevPipeline.Job(id: "abcdef", tabID: 1, page: "https://example.com/v", step: .speech, duration: 90)
        job.fetched = 40
        job.analysed = 38
        dev.show(job: job, speech: [1.0...3.0, 4.0...5.5, 8.0...8.4, 12.0...20.0, 30.0...37.0])
        dev.selection = 4.0...5.5
        let root = ContentView()
            .environment(engine)
            .environment(JishoBrowser())
            .environment(SentenceAnalyzer(makeClient: { nil }))
            .environment(panel)
            .environment(video)
            .environment(Prefetcher(engine: engine, video: video))
            .environment(dev)
            .environment(ActivityLog())
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }

        let view = try XCTUnwrap(window.contentView)
        func views<Found: NSView>(_ type: Found.Type, in v: NSView) -> [Found] {
            ((v as? Found).map { [$0] } ?? []) + v.subviews.flatMap { views(type, in: $0) }
        }
        let canvas = try XCTUnwrap(
            TestScreen.wait { views(TimelineCanvas.CanvasView.self, in: view).first }, "no timeline under the captions"
        )
        let tabs = try XCTUnwrap(views(NSSegmentedControl.self, in: view).last, "no panel tabs")
        XCTAssertLessThan(
            canvas.convert(canvas.visibleRect, to: nil).maxX, tabs.convert(tabs.bounds, to: nil).minX,
            "on the captions' side"
        )
        XCTAssertGreaterThan(canvas.frame.width, 0)
        XCTAssertEqual(canvas.speech.count, 5)
        XCTAssertEqual(canvas.selection, 4.0...5.5)
        XCTAssertEqual(views(NSSegmentedControl.self, in: view).map(\.segmentCount), [2, 2], "mode switch and panel tabs")
        XCTAssertNotNil(views(RowSplitHandle.HandleView.self, in: view).first, "a line above the timeline")
        snapshot(view, "dev-timeline")
    }

    private func snapshot(_ view: NSView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
