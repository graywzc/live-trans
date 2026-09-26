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
    /// Paired but not connected, so not a Core Audio device yet.
    private let airpods2 = Device(id: "20-F4-D4-2A-1A-B9:output", name: "AirPods4-2")

    private var snapshot: SoundOutput.Snapshot {
        SoundOutput.Snapshot(
            devices: [plugable, blackhole, speakers, airpods],
            aggregates: [
                Aggregate(uid: "multi-speakers", subDeviceUIDs: ["speakers", "blackhole"], name: "BlackHole+Speaker"),
                Aggregate(uid: "multi-airpods", subDeviceUIDs: ["airpods", "blackhole"], name: "BlackHole+AP4"),
                Aggregate(uid: "hdmi-pair", subDeviceUIDs: ["speakers", "hdmi"], name: "Speakers+HDMI"),
                Aggregate(
                    uid: "multi-airpods-2", subDeviceUIDs: ["20-F4-D4-2A-1A-B9:output", "blackhole"],
                    name: "BlackHole+AP4-2"
                ),
            ],
            current: "plugable", capture: "blackhole", captureName: "BlackHole 2ch",
            headphones: [airpods, airpods2]
        )
    }

    func testOffersEverythingButTheCaptureDevice() {
        // Connected headphones are listed once, as the audio device they are.
        XCTAssertEqual(snapshot.choices, [plugable, speakers, airpods, airpods2])
        XCTAssertFalse(snapshot.needsConnecting(airpods))
        XCTAssertTrue(snapshot.needsConnecting(airpods2))
    }

    func testHeadphonesComeFromTheProfilerWithTheirGivenNames() throws {
        let report = """
        {"SPBluetoothDataType": [{
          "device_connected": [{"AirPods4-2": {"device_address": "20:F4:D4:2A:1A:B9", "device_minorType": "Headphones"}}],
          "device_not_connected": [
            {"AirPods 4": {"device_address": "7C:C0:6F:9E:B5:75", "device_minorType": "Headphones"}},
            {"Larry’s iPhone": {"device_address": "28:2D:7F:76:DD:DF"}},
            {"mini4": {"device_address": "E9:1B:7E:E3:F4:E9", "device_minorType": "Computer"}}
          ]
        }]}
        """
        XCTAssertEqual(BluetoothHeadphones.parse(profile: Data(report.utf8)), [
            Device(id: "20-F4-D4-2A-1A-B9:output", name: "AirPods4-2"),
            Device(id: "7C-C0-6F-9E-B5-75:output", name: "AirPods 4"),
        ])
        XCTAssertEqual(BluetoothHeadphones.parse(profile: Data()), [])
    }

    func testUnconnectedHeadphonesAreNamedByTheirAddress() {
        XCTAssertEqual(BluetoothHeadphones.outputUID(address: "20:f4:d4:2a:1a:b9"), "20-F4-D4-2A-1A-B9:output")
        // So the Multi-Output Device for them is known before they connect.
        XCTAssertEqual(snapshot.feed(for: airpods2)?.name, "BlackHole+AP4-2")
        XCTAssertEqual(
            OutputList.detail(feed: snapshot.feed(for: airpods2), captureName: "BlackHole 2ch", unconnected: true),
            "connect · captions via BlackHole+AP4-2"
        )
    }

    func testChoosingUnconnectedHeadphonesWaitsForThem() {
        let output = SoundOutput(snapshot: snapshot)
        output.choose(airpods2)
        XCTAssertEqual(output.connecting, airpods2)
        XCTAssertEqual(output.label, "Connecting AirPods4-2…")
        XCTAssertEqual(output.snapshot.listening, plugable, "the output is not moved until they appear")
        output.choose(speakers)
        XCTAssertNil(output.connecting, "choosing something else gives up on them")
        XCTAssertEqual(output.label, "MacBook Air Speakers")
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
        let window = TestScreen.window(width: 360, height: 180)
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
        // covered above; here, that the four rows are drawn, the chosen one
        // (the second) tinted orange.
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func isOrange(_ color: NSColor?) -> Bool {
            guard let c = color?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > c.blueComponent + 0.05 && c.greenComponent > c.blueComponent
        }
        // In pixels, whatever the display's scale: the four rows fill the
        // 180-point window in quarters, near enough.
        let rowHeight = rep.pixelsHigh / 4
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
