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
        log.record("one", at: noon)
        log.record("two", at: noon)
        XCTAssertEqual(log.entries.map(\.text), ["one", "two"])
    }

    func testTheOldestLinesAreLetGo() {
        let log = ActivityLog()
        for n in 0..<(ActivityLog.kept + 5) {
            log.record("line \(n)", at: noon.addingTimeInterval(Double(n)))
        }
        XCTAssertEqual(log.entries.count, ActivityLog.kept)
        XCTAssertEqual(log.entries.first?.text, "line 5")
    }

    func testTheServersLinesAreTakenFromWhereItLeftOff() {
        let log = ActivityLog()
        log.take(answer(boot: "a", next: 2, [(1, 0, "loading"), (2, 1, "listening")]))
        XCTAssertEqual(log.since, 2)
        log.take(answer(boot: "a", next: 3, [(3, 2, "job started")]))
        XCTAssertEqual(log.entries.map(\.text), ["loading", "listening", "job started"])
        XCTAssertEqual(log.since, 3)
    }

    func testARestartedServerIsAskedFromTheTop() {
        let log = ActivityLog()
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

    func testTheStepsCanBeLeftOut() {
        let log = ActivityLog()
        log.record("job: 60 s, 9 lines", from: .host, at: noon)
        log.take(HostEvents(boot: "a", next: 1, events: [
            .init(seq: 1, at: noon.timeIntervalSince1970 + 1, text: "cut at 0:02.4", detail: true),
        ]))
        XCTAssertEqual(log.shown.map(\.text), ["job: 60 s, 9 lines", "cut at 0:02.4"])
        XCTAssertEqual(log.entries.map(\.isDetail), [false, true])
        log.showsDetails = false
        XCTAssertEqual(log.shown.map(\.text), ["job: 60 s, 9 lines"])
    }

    func testClearingEmptiesTheList() {
        let log = ActivityLog()
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

    /// The tab in the real window, with lines from both machines in it.
    func testTheTabListsBothMachines() throws {
        let panel = SidePanel()
        panel.show(.activity)
        let log = ActivityLog()
        let start = Date(timeIntervalSince1970: 1_000_000)
        log.record("status: connecting", at: start)
        log.record("loading ASR on cuda", from: .host, at: start.addingTimeInterval(1))
        log.record("utterance 0: 3.2 s, noise floor 40, threshold 120", at: start.addingTimeInterval(9))
        log.record("Whisper (beam 5, 0 characters of context): 9 words in 2 segments in 0.6s", from: .host, at: start.addingTimeInterval(9.6), detail: true)
        log.record("  segment: 駅まで歩いたのに", from: .host, at: start.addingTimeInterval(9.6), detail: true)
        log.record("  cut …歩いたのに | みなさん… (Whisper began a new segment): at 0:02.4, in a pause of 0.80s", from: .host, at: start.addingTimeInterval(9.7), detail: true)
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
            .environment(log)
        let window = TestScreen.window(width: 960, height: 520)
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }

        let view = try XCTUnwrap(window.contentView)
        func controls(_ v: NSView) -> [NSControl] {
            ((v as? NSControl).map { [$0] } ?? []) + v.subviews.flatMap(controls)
        }
        let picker = try XCTUnwrap(
            TestScreen.wait { controls(view).compactMap { $0 as? NSSegmentedControl }.first }, "no panel tab picker"
        )
        XCTAssertEqual(picker.segmentCount, 3)
        XCTAssertEqual(picker.selectedSegment, 2)

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/activity-tab.png"))
        }
    }
}
