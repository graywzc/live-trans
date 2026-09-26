import SwiftUI
import XCTest
@testable import LiveTrans

@MainActor
final class SoundOutputTests: XCTestCase {
    private typealias Device = SoundOutput.Device
    private typealias Aggregate = AudioHardware.Aggregate

    private let speakers = Device(id: "speakers", name: "MacBook Air Speakers")
    private let airpods = Device(id: "airpods", name: "AirPods 4")
    private let plugable = Device(id: "plugable", name: "Plugable Audio")
    private let blackhole = Device(id: "blackhole", name: "BlackHole 2ch")

    private var snapshot: SoundOutput.Snapshot {
        SoundOutput.Snapshot(
            devices: [plugable, blackhole, speakers, airpods],
            aggregates: [
                Aggregate(uid: "multi-speakers", subDeviceUIDs: ["speakers", "blackhole"], name: "BlackHole+Speaker"),
                Aggregate(uid: "multi-airpods", subDeviceUIDs: ["airpods", "blackhole"], name: "BlackHole+AP4"),
                Aggregate(uid: "hdmi-pair", subDeviceUIDs: ["speakers", "hdmi"], name: "Speakers+HDMI"),
            ],
            current: "plugable", capture: "blackhole", captureName: "BlackHole 2ch"
        )
    }

    func testOffersEverythingButTheCaptureDevice() {
        XCTAssertEqual(snapshot.choices, [plugable, speakers, airpods])
    }

    func testListeningOnAPlainOutput() {
        XCTAssertEqual(snapshot.listening, plugable)
        XCTAssertEqual(snapshot.label, "Plugable Audio")
    }

    func testListeningThroughAMultiOutputDevice() {
        var routed = snapshot
        routed.current = "multi-speakers"
        // Left on BlackHole+Speaker after a session: that is the speakers.
        XCTAssertEqual(routed.listening, speakers)
        XCTAssertEqual(routed.label, "MacBook Air Speakers")
    }

    func testAnUnrelatedAggregateIsShownByName() {
        var odd = snapshot
        odd.current = "hdmi-pair"
        XCTAssertNil(odd.listening)
        XCTAssertEqual(odd.label, "Speakers+HDMI")
        odd.current = nil
        XCTAssertEqual(odd.label, "No output")
    }

    func testSaysWhichMultiOutputDeviceCarriesTheCaptions() {
        XCTAssertEqual(snapshot.feed(for: airpods)?.name, "BlackHole+AP4")
        XCTAssertEqual(snapshot.feed(for: speakers)?.name, "BlackHole+Speaker")
        XCTAssertNil(snapshot.feed(for: plugable))
        XCTAssertEqual(
            OutputList.detail(feed: snapshot.feed(for: airpods), captureName: "BlackHole 2ch"),
            "captions via BlackHole+AP4"
        )
        XCTAssertEqual(
            OutputList.detail(feed: nil, captureName: "BlackHole 2ch"),
            "no Multi-Output Device pairs it with BlackHole 2ch"
        )
    }

    func testChoosingMovesTheOutput() {
        let output = SoundOutput(snapshot: snapshot)
        output.choose(airpods)
        XCTAssertEqual(output.snapshot.listening, airpods)
    }

    /// The list as it is shown, for a look at SNAPSHOT_DIR/output-list.png.
    func testListShowsEachDeviceWithItsFeed() throws {
        var shown = snapshot
        shown.current = "multi-speakers"
        let output = SoundOutput(snapshot: shown)
        let window = TestScreen.window(width: 360, height: 160)
        window.contentView = NSHostingView(
            rootView: OutputList(output: output) {}
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.black)
                .preferredColorScheme(.dark)
        )
        window.orderFrontRegardless()
        defer { window.close() }
        pump()

        let view = try XCTUnwrap(window.contentView)
        // SwiftUI text is not a view of its own, so what the rows say is
        // covered above; here, that the three rows are drawn, the chosen one
        // (the second) tinted orange.
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func isOrange(_ color: NSColor?) -> Bool {
            guard let c = color?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > c.blueComponent + 0.05 && c.greenComponent > c.blueComponent
        }
        // In pixels, whatever the display's scale: the rows fill the top of
        // the 160-point window in thirds, near enough.
        let rowHeight = rep.pixelsHigh / 3
        let x = rep.pixelsWide / 2
        XCTAssertFalse(isOrange(rep.colorAt(x: x, y: rowHeight / 2)), "first row is not chosen")
        XCTAssertTrue(isOrange(rep.colorAt(x: x, y: rowHeight + rowHeight / 2)), "second row is chosen")
        snapshot(view, "output-list")
    }

    private func pump() {
        for _ in 0..<2 {
            while let event = NSApp.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func snapshot(_ view: NSView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
