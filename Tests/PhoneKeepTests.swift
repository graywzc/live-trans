import SwiftUI
import XCTest
@testable import LiveTrans

/// The video kept for the phone, from the Mac's side: what the host's
/// status carries, what the requests ask, and what the Dev tab's control
/// says and does.
@MainActor
final class PhoneKeepTests: XCTestCase {
    private static let size = CGSize(width: 320, height: 40)
    private var window: NSWindow!
    private var kept = 0
    private var forgotten = 0

    override func setUp() async throws {
        kept = 0
        forgotten = 0
        window = TestScreen.window(size: Self.size)
    }

    override func tearDown() async throws {
        window.close()
        window = nil
    }

    // MARK: The host's word

    func testTheStatusCarriesTheHostsWordOnThePhonesCopy() throws {
        let status = try JSONDecoder().decode(PrefetchStatus.self, from: Data("""
        {"state": "done", "fetched": 60, "ready": 60, "count": 0, "lines": [], "bundle": "running", "bundle_fetched": 12.5}
        """.utf8))
        XCTAssertEqual(status.bundle, "running")
        XCTAssertEqual(status.bundleFetched, 12.5)
        let older = try JSONDecoder().decode(PrefetchStatus.self, from: Data("""
        {"state": "running", "fetched": 1, "ready": 0, "count": 0, "lines": []}
        """.utf8))
        XCTAssertNil(older.bundle, "a server from before says nothing of it")
        XCTAssertNil(older.bundleFetched)
    }

    func testTheKeepRequestNamesTheJobAndCarriesTheTitle() throws {
        let base = URL(string: "http://gpu-host:8770")!
        let request = ASRClient.keepForPhoneRequest(baseURL: base, job: "abc123", title: "A made-up episode")
        XCTAssertEqual(request.url?.path, "/prefetch/abc123/bundle")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["title": "A made-up episode"])
        let untitled = ASRClient.keepForPhoneRequest(baseURL: base, job: "abc123", title: nil)
        let bare = try JSONSerialization.jsonObject(with: XCTUnwrap(untitled.httpBody)) as? [String: String]
        XCTAssertEqual(bare, ["title": ""])
    }

    func testForgettingThePhonesCopyAsksForTheBundleAlone() {
        let base = URL(string: "http://gpu-host:8770")!
        let page = "https://example.com/watch?v=1"
        let copy = ASRClient.clearDevCacheRequest(baseURL: base, page: page, bundleOnly: true)
        XCTAssertEqual(copy.httpMethod, "POST")
        XCTAssertEqual(copy.url?.path, "/devcache/clear")
        XCTAssertEqual(
            URLComponents(url: copy.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "page", value: page), URLQueryItem(name: "bundle", value: "1")]
        )
        let whole = ASRClient.clearDevCacheRequest(baseURL: base, page: page, bundleOnly: false)
        XCTAssertEqual(
            URLComponents(url: whole.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "page", value: page)]
        )
        let all = ASRClient.clearDevCacheRequest(baseURL: base, page: nil, bundleOnly: true)
        XCTAssertNil(
            URLComponents(url: all.url!, resolvingAgainstBaseURL: false)?.queryItems,
            "the whole cache: the phone's copies go with everything else"
        )
    }

    func testWhatIsToldWhenTheHostsWordChanges() {
        XCTAssertNil(DevPipeline.phoneCopyNews(from: "none", to: "none"))
        XCTAssertNil(DevPipeline.phoneCopyNews(from: "none", to: "running"), "the control shows the fetch")
        XCTAssertEqual(
            DevPipeline.phoneCopyNews(from: "running", to: "done"), "The video is on the host for the iPhone, with its captions"
        )
        XCTAssertEqual(
            DevPipeline.phoneCopyNews(from: "running", to: "failed: the video came short: 100s of 1400s"),
            "Keeping the video for the iPhone failed: the video came short: 100s of 1400s"
        )
        XCTAssertNil(DevPipeline.phoneCopyNews(from: "done", to: "none"), "forgotten: the control says so")
    }

    func testWhenTheHostCanBeAsked() {
        let dev = DevPipeline(engine: CaptionEngine(), video: ChromeVideo())
        XCTAssertFalse(dev.canKeepForPhone, "no job")
        var job = DevPipeline.Job(id: "a", tabID: 1, page: "p", step: .speech, duration: 60)
        dev.show(job: job, speech: [])
        XCTAssertFalse(dev.canKeepForPhone, "the captions are still being made")
        job.captions = "done"
        dev.show(job: job, speech: [])
        XCTAssertTrue(dev.canKeepForPhone)
        job.bundle = "running"
        dev.show(job: job, speech: [])
        XCTAssertFalse(dev.canKeepForPhone, "the host is fetching it already")
        job.bundle = "done"
        dev.show(job: job, speech: [])
        XCTAssertTrue(dev.canKeepForPhone, "kept before, it can be kept again")
    }

    // MARK: The control

    func testWhatTheControlSays() {
        XCTAssertEqual(PhoneKeepControl.title(bundle: "none", fetched: 0, duration: 1442), "Keep for iPhone")
        XCTAssertEqual(PhoneKeepControl.title(bundle: "failed: ffmpeg: exited 1", fetched: 0, duration: 1442), "Keep for iPhone")
        XCTAssertEqual(PhoneKeepControl.title(bundle: "running", fetched: 620.5, duration: 1442), "Keeping for iPhone · 43%")
        XCTAssertEqual(
            PhoneKeepControl.title(bundle: "running", fetched: 1442, duration: 1442), "Keeping for iPhone · 99%",
            "done is the host's word, not the count's"
        )
        XCTAssertEqual(PhoneKeepControl.title(bundle: "running", fetched: 30, duration: nil), "Keeping for iPhone…")
        XCTAssertEqual(PhoneKeepControl.title(bundle: "done", fetched: 1442, duration: 1442), "On the host for the iPhone")
        XCTAssertEqual(
            PhoneKeepControl.help(bundle: "none", canKeep: true),
            "Have the host keep this video with its captions, for the iPhone app to download"
        )
        XCTAssertEqual(
            PhoneKeepControl.help(bundle: "none", canKeep: false),
            "Once the step's captions have reached the end, the host can keep the video with them for the iPhone"
        )
        XCTAssertEqual(PhoneKeepControl.help(bundle: "running", canKeep: false), "The host is fetching the video for the iPhone")
        XCTAssertEqual(
            PhoneKeepControl.help(bundle: "failed: stopped", canKeep: true),
            "Keeping the video failed: stopped. Have the host keep this video with its captions, for the iPhone app to download"
        )
        XCTAssertEqual(
            PhoneKeepControl.help(bundle: "done", canKeep: true),
            "The video is on the host with its captions, for the iPhone app to download"
        )
    }

    // MARK: In a window

    private func show(bundle: String, canKeep: Bool) {
        let control = PhoneKeepControl(
            bundle: bundle, fetched: 620, duration: 1442, canKeep: canKeep,
            onKeep: { [unowned self] in kept += 1 }, onForget: { [unowned self] in forgotten += 1 }
        )
        // As the Dev tab shows it: in the app's dark window, in the
        // timeline row's font and style.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: control
                .font(.caption.monospacedDigit())
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
                .background(Color.black)
        )
        window.makeKeyAndOrderFront(nil)
        pump()
        pump()
    }

    func testTheButtonAsksOnlyOnceTheCaptionsAreDoneAndNotWhileFetching() {
        show(bundle: "none", canKeep: false)
        snapshot("phone-keep-not-yet")
        click(at: CGPoint(x: 50, y: 20))
        XCTAssertEqual(kept, 0, "nothing to keep yet")
        show(bundle: "none", canKeep: true)
        snapshot("phone-keep-ready")
        click(at: CGPoint(x: 50, y: 20))
        XCTAssertEqual(kept, 1)
        show(bundle: "running", canKeep: false)
        snapshot("phone-keep-running")
        click(at: CGPoint(x: 50, y: 20))
        XCTAssertEqual(kept, 1, "a fetch running is not asked for again")
        show(bundle: "done", canKeep: true)
        snapshot("phone-keep-done")
        XCTAssertEqual(forgotten, 0)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func click(at point: CGPoint) {
        NSApp.postEvent(event(.leftMouseDown, at: point), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, at: point), atStart: false)
        pump()
    }

    private func pump() {
        while let event = NSApp.nextEvent(
            matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
    }

    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
