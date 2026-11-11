import SwiftUI
import XCTest
@testable import LiveTrans

/// Activity's bars, one for each of the host's tasks on the video.
@MainActor
final class JobProgressTests: XCTestCase {
    private static let reached = [("k2", 900.0), ("nemo", 600.0), ("qwen", 300.0)]
    private static let translated = [("k2", 900.0), ("nemo", 450.0), ("qwen", 150.0)]

    /// In the order each works through the video, each named as the
    /// running list names it.
    func testEachTaskHasABarOfItsOwnInTheOrderTheyWork() {
        let tasks = DevPipeline.progress(
            fetched: 1050, total: 1200, reached: Self.reached, translated: Self.translated,
            speakers: .init(told: 600, telling: 600...900), cut: 600
        )
        XCTAssertEqual(tasks.map(\.task), [
            "Audio download", "k2 captioning", "Speaker detection", "Cutting captions at speaker changes",
            "nemo captioning", "qwen captioning",
            "Translating k2 captions", "Translating nemo captions", "Translating qwen captions",
        ])
        XCTAssertEqual(tasks.map(\.reached), [1050, 900, 600, 600, 600, 300, 900, 450, 150])
        XCTAssertEqual(tasks[2].underWay, 600...900, "the stretch being told apart")
        XCTAssertTrue(tasks.allSatisfy { RunningStatus.mark(for: $0.task) != nil }, "each has its swatch in the running list")

        let done = DevPipeline.progress(
            fetched: 1200, total: 1200, reached: Self.reached, translated: [], speakers: .init(told: 0, done: true), cut: nil
        )
        XCTAssertEqual(done.first { $0.task == "Speaker detection" }, .init(task: "Speaker detection", reached: 1200))
        XCTAssertFalse(done.contains { $0.task.hasPrefix("Cutting") }, "a host from before says nothing of the cuts")
    }

    /// Each bar lit from the start as far as its task has come, whatever its
    /// color, and the viewer's place marked across them.
    func testEachBarIsLitAsFarAsItsTaskHasCome() throws {
        let tasks = DevPipeline.progress(
            fetched: 1050, total: 1200, reached: Self.reached, translated: Self.translated,
            speakers: .init(told: 600, telling: 600...900), cut: 600
        )
        let size = CGSize(width: 640, height: 200)
        let window = TestScreen.window(size: size)
        defer { window.close() }
        window.contentView = NSHostingView(
            rootView: JobProgressView(total: 1200, tasks: tasks, playhead: 1150, running: ["Speaker detection"])
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.black)
        )
        window.makeKeyAndOrderFront(nil)
        pump()
        let view = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func brightness(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        // The bars run from past the names to before the times; each row is
        // found by the brightest line across its bar's lit start.
        let left = JobProgressView.nameWidth + 8
        let right = size.width - 8 - 44
        let x = { (seconds: Double) in left + (right - left) * CGFloat(seconds / 1200) }
        let rows = stride(from: CGFloat(0), to: size.height, by: 1).filter { brightness(x(20), $0) > 0.25 }
        // One band of lit lines per task.
        let bands = zip(rows, [-10] + rows).filter { $0 - $1 > 1 }.map(\.0)
        XCTAssertEqual(bands.count, tasks.count, "a bar for each task")
        for (task, top) in zip(tasks, bands) where task.underWay == nil {
            let y = top + 1
            XCTAssertGreaterThan(brightness(x(task.reached - 40), y), 0.25, "\(task.task) lit to \(task.reached)")
            XCTAssertLessThan(brightness(x(task.reached + 40), y), 0.2, "\(task.task) dark past \(task.reached)")
        }
        // The playhead's orange tick crosses every bar.
        let tick = bands.filter { band in
            let color = rep.colorAt(x: Int(x(1150) * scale), y: Int((band + 1) * scale))?.usingColorSpace(.deviceRGB)
            return (color?.redComponent ?? 0) > 0.7 && (color?.blueComponent ?? 1) < 0.3
        }
        XCTAssertEqual(tick.count, tasks.count, "the viewer's place on each bar")
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/job-progress.png"))
        }
    }

    /// Played ahead of the captions, each bar is lit in the stretch from
    /// there as far as its task has come in it too.
    func testEachBarIsLitInTheStretchesPlayedAheadInto() {
        let stretches = [
            CaptionStretch(start: 0, end: 600, ready: 300, spoken: 0, cut: 0),
            CaptionStretch(start: 600, end: nil, ready: 900, spoken: 800, cut: 700),
        ]
        let own: [(range: ClosedRange<Double>, english: Bool)] = [
            (10...20, true), (610...620, true), (880...890, false),
        ]
        let others = [OtherHearing(start: 610, end: 620, nemo: "甲", nemoEnglish: "a")]
        let ahead = DevPipeline.ahead(stretches: stretches, total: 1200, own: own, others: others)
        XCTAssertEqual(ahead["k2 captioning"], [600...900])
        XCTAssertEqual(ahead["Speaker detection"], [600...800])
        XCTAssertEqual(ahead["Cutting captions at speaker changes"], [600...700])
        XCTAssertEqual(ahead["nemo captioning"], [600...620])
        XCTAssertNil(ahead["qwen captioning"], "nothing heard there yet")
        XCTAssertEqual(ahead["Translating k2 captions"], [600...620])
        XCTAssertEqual(ahead["Translating nemo captions"], [600...620])

        let tasks = DevPipeline.adding(ahead: ahead, to: DevPipeline.progress(
            fetched: 1200, total: 1200, reached: Self.reached, translated: Self.translated,
            speakers: .init(told: 0), cut: 0
        ))
        XCTAssertEqual(tasks.first { $0.task == "k2 captioning" }?.ahead, [600...900])
        XCTAssertEqual(tasks.first { $0.task == "Audio download" }?.ahead, [])
        // A job never played ahead has nothing there.
        XCTAssertTrue(DevPipeline.ahead(stretches: Array(stretches.prefix(1)), total: 1200, own: own, others: others).isEmpty)
    }

    private func pump() {
        while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}
