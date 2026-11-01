import SwiftUI
import XCTest
@testable import LiveTransMobile

/// The player's model and rows: the captions made of a bundle, which one
/// is lit as the video moves, a sentence played again and going on from
/// it, the list following or staying, and where the video was left.
@MainActor
final class PlayerTests: XCTestCase {
    private var bundle: VideoBundle!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        bundle = try VideoBundle.decode(Data(Fixtures.bundle.utf8))
        suite = "PlayerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model() -> PlaybackModel {
        PlaybackModel(bundle: bundle, video: nil, defaults: defaults)
    }

    func testTheBundlesLinesBecomeCaptionsWithReadingsAndPlaces() {
        let captions = PlaybackModel.captions(of: bundle)
        XCTAssertEqual(captions.map(\.id), [0, 1])
        XCTAssertEqual(captions[0].japanese, "窓の外で鳥が歌っている。")
        XCTAssertEqual(captions[0].english, "A bird is singing outside the window.")
        XCTAssertEqual(captions[0].moment, VideoMoment(tabID: 0, url: bundle.id, seconds: 1.2, end: 3.8, duration: 95.5))
        XCTAssertEqual(captions[1].moment?.seconds, 4.5)
        XCTAssertEqual(captions[0].ruby.map(\.base).joined(), "窓の外で鳥が歌っている。", "the words make the sentence")
        XCTAssertFalse(captions[0].ruby.compactMap(\.reading).isEmpty, "the kanji have readings")
    }

    func testTheLitCaptionFollowsTheVideo() {
        let model = model()
        model.observe(seconds: 0.5)
        XCTAssertNil(model.playingID)
        XCTAssertEqual(model.lull, Lull(captionID: 0, isAfter: false, seconds: 0), "before the first sentence")
        model.observe(seconds: 2.0)
        XCTAssertEqual(model.playingID, 0)
        XCTAssertNil(model.lull)
        model.observe(seconds: 4.0)
        XCTAssertEqual(model.playingID, 0, "just after a sentence it is still that sentence")
        model.observe(seconds: 5.0)
        XCTAssertEqual(model.playingID, 1)
        model.observe(seconds: 20.0)
        XCTAssertNil(model.playingID)
        XCTAssertEqual(model.lull, Lull(captionID: 1, isAfter: true, seconds: 20), "after the last one spoken")
        XCTAssertEqual(model.time, 20.0)
    }

    func testASentenceIsPlayedFromJustBeforeItToJustAfterItsEnd() {
        let captions = PlaybackModel.captions(of: bundle)
        let window = PlaybackModel.replayWindow(of: captions[1].moment!)
        XCTAssertEqual(window.from, 4.0, accuracy: 1e-9)
        XCTAssertEqual(window.to!, 7.2, accuracy: 1e-9)
        let early = PlaybackModel.replayWindow(of: VideoMoment(tabID: 0, url: "b", seconds: 0.2))
        XCTAssertEqual(early.from, 0, "never before the start")
        XCTAssertNil(early.to, "no end to stop at")
        // Asked for, the sentence is lit at once, before the video gets
        // there (just before it, the one before would still be).
        let model = model()
        model.replay(captions[1])
        XCTAssertEqual(model.playingID, 1)
        XCTAssertNil(model.lull)
        XCTAssertEqual(model.time, 4.0, accuracy: 1e-9)
    }

    func testContinueGoesOnPastTheSentenceEnd() {
        let model = model()
        XCTAssertFalse(model.stopsAtSentenceEnd)
        model.replay(PlaybackModel.captions(of: bundle)[1])
        XCTAssertTrue(model.stopsAtSentenceEnd)
        model.continuePlaying()
        XCTAssertFalse(model.stopsAtSentenceEnd, "the stop is gone")
    }

    func testCaptionsMadeAwayFromTheScreenCountEveryLine() async {
        var counted: [Int] = []
        let captions = await PlaybackModel.captions(of: bundle) { counted.append($0) }
        XCTAssertEqual(captions, PlaybackModel.captions(of: bundle))
        XCTAssertEqual(counted, [1, 2])
    }

    func testAVideoThatCannotOpenSaysSo() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(UUID().uuidString).mp4")
        let model = PlaybackModel(bundle: bundle, video: missing, defaults: defaults)
        XCTAssertEqual(model.video, .loading)
        model.start()
        defer { model.stop() }
        for _ in 0..<100 where model.video == .loading {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.video, .failed)
    }

    func testTheVersionIsTheBuildsCommitWhenStamped() {
        XCTAssertEqual(AppVersion.text(build: "v0.1.82-2-gabc1234\n", marketing: "0.1.0"), "v0.1.82-2-gabc1234")
        XCTAssertEqual(AppVersion.text(build: nil, marketing: "0.1.0"), "0.1.0")
        XCTAssertEqual(AppVersion.text(build: nil, marketing: nil), "unknown")
    }

    func testTheTimingsSumUpAPeriodAndStartAnother() {
        var timings = PlaybackTimings()
        XCTAssertTrue(timings.isEmpty)
        timings.frame(ms: 16)
        timings.frame(ms: 16)
        timings.frame(ms: 120)
        timings.highlight(lateMs: 30)
        timings.highlight(lateMs: 90)
        timings.highlight(lateMs: -5)
        timings.tap(ms: 150)
        let report = timings.report(seconds: 30)
        XCTAssertEqual(report.frames, 3)
        XCTAssertEqual(report.hitches, 1)
        XCTAssertEqual(report.worstFrameMs, 120)
        XCTAssertEqual(report.highlights, 3)
        XCTAssertEqual(report.highlightLateMedianMs, 30)
        XCTAssertEqual(report.highlightLateMaxMs, 90)
        XCTAssertEqual(report.taps, 1)
        XCTAssertEqual(report.tapMaxMs, 150)
        XCTAssertTrue(timings.isEmpty)
    }

    func testTimingsGoToTheBundlesMachine() {
        XCTAssertEqual(
            PlaybackTimings.endpoint(host: URL(string: "https://gpu.example.ts.net/livetrans"))?.absoluteString,
            "http://gpu.example.ts.net:8773/timings"
        )
        XCTAssertNil(PlaybackTimings.endpoint(host: nil))
        XCTAssertNil(PlaybackTimings.endpoint(host: URL(string: "file:///tmp/bundles")))
    }

    func testTheReportHasTheFieldsTheHostTakes() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try JSONSerialization.jsonObject(with: encoder.encode(PlaybackTimings.Report())) as? [String: Any]
        XCTAssertEqual(Set(json?.keys ?? [:].keys), [
            "build", "seconds", "frames", "hitches", "worst_frame_ms", "highlights", "highlight_late_median_ms",
            "highlight_late_max_ms", "taps", "tap_median_ms", "tap_max_ms", "route", "audio_latency_ms",
            "low_power", "thermal",
        ])
    }

    func testWhereTheVideoWasLeftIsKeptForNextTimeButNotNearTheEnds() {
        PlaybackModel.remember(30, for: bundle, in: defaults)
        XCTAssertEqual(PlaybackModel.restoredPosition(for: bundle, in: defaults), 30)
        PlaybackModel.remember(2, for: bundle, in: defaults)
        XCTAssertNil(PlaybackModel.restoredPosition(for: bundle, in: defaults), "at the start, start over")
        PlaybackModel.remember(60, for: bundle, in: defaults)
        PlaybackModel.remember(93, for: bundle, in: defaults)
        XCTAssertNil(PlaybackModel.restoredPosition(for: bundle, in: defaults), "at the end, start over")
        PlaybackModel.remember(60, for: bundle, in: defaults)
        PlaybackModel.forgetPosition(for: bundle.id, in: defaults)
        XCTAssertNil(PlaybackModel.restoredPosition(for: bundle, in: defaults), "gone with the bundle")
        let model = model()
        model.observe(seconds: 42)
        model.remember()
        XCTAssertEqual(PlaybackModel.restoredPosition(for: bundle, in: defaults), 42)
    }

    func testARowRedrawsOnlyForWhatItDraws() {
        let caption = PlaybackModel.captions(of: bundle)[0]
        func row(fontSize: Double = 20, isCurrent: Bool = false) -> PhoneCaptionRow {
            PhoneCaptionRow(caption: caption, fontSize: fontSize, showFurigana: true, isCurrent: isCurrent, onTap: {})
        }
        XCTAssertEqual(row(), row(), "a new closure is not a change")
        XCTAssertNotEqual(row(), row(isCurrent: true))
        XCTAssertNotEqual(row(), row(fontSize: 24))
        var picked = row()
        picked.picked = "nemo"
        XCTAssertNotEqual(row(), picked)
    }

    func testThePlaceIsKeptWhilePlayingInCaseTheAppIsClosed() {
        let model = model()
        model.observe(seconds: 30)
        XCTAssertEqual(PlaybackModel.restoredPosition(for: bundle, in: defaults), 30)
        model.observe(seconds: 33)
        XCTAssertEqual(PlaybackModel.restoredPosition(for: bundle, in: defaults), 30, "not at every step")
        model.observe(seconds: 36)
        XCTAssertEqual(PlaybackModel.restoredPosition(for: bundle, in: defaults), 36)
    }

    private func versionsModel() throws -> PlaybackModel {
        PlaybackModel(bundle: try VideoBundle.decode(Data(Fixtures.versionsBundle.utf8)), video: nil, defaults: defaults)
    }

    func testEachRecognizersTextComesWithItsTranslationAndTheCaptionsOwnFirst() throws {
        let captions = try versionsModel().captions
        XCTAssertEqual(captions[0].versions.map(\.name), ["k2", "nemo", "qwen"])
        XCTAssertEqual(captions[0].versions[1].english, "窗外有鸟在歌唱。")
        XCTAssertEqual(captions[0].versions[2].ruby.map(\.base).joined(), "窓の外で鳥が歌ってる")
        XCTAssertEqual(captions[1].versions.map(\.name), ["k2", "nemo"])
        XCTAssertTrue(captions[2].versions.isEmpty, "heard by k2 alone, the row is as ever")
        XCTAssertTrue(PlaybackModel.captions(of: bundle)[0].versions.isEmpty, "an older bundle")
    }

    func testAPickedVersionIsTheCaptionAndCanBeTakenBack() throws {
        let model = try versionsModel()
        let caption = model.captions[0]
        XCTAssertEqual(caption.heard(by: nil), caption)
        let heard = caption.heard(by: "qwen")
        XCTAssertEqual(heard.japanese, "窓の外で鳥が歌ってる")
        XCTAssertEqual(heard.english, "窗外鸟儿在唱")
        XCTAssertEqual(heard.moment, caption.moment)
        XCTAssertEqual(heard.id, caption.id)

        model.pick("qwen", for: caption)
        XCTAssertEqual(model.picks, [0: "qwen"])
        model.pick(nil, for: caption)
        XCTAssertEqual(model.picks, [:])
    }

    func testPicksAreKeptWithTheVideoUntilItIsDeleted() throws {
        let model = try versionsModel()
        model.pick("nemo", for: model.captions[1])
        XCTAssertEqual(try versionsModel().picks, [1: "nemo"], "the next opening")
        XCTAssertEqual(self.model().picks, [:], "another video has its own")
        PlaybackModel.forgetPicks(for: model.bundle.id, in: defaults)
        XCTAssertEqual(try versionsModel().picks, [:])
    }

    func testTheVideoIsReopenedOnlyWhenTheAppStarts() {
        var reopen = ReopenOnce()
        XCTAssertEqual(reopen.take("video"), "video", "started again where it was closed")
        XCTAssertNil(reopen.take("video"), "the list again, after Back: it stays the list")
        var nothingOpen = ReopenOnce()
        XCTAssertNil(nothingOpen.take(""))
        XCTAssertNil(nothingOpen.take("video"), "chosen since the app started")
    }

    func testTheListFollowsUntilAFingerMovesIt() {
        var follow = FollowState()
        XCTAssertTrue(follow.shouldShow(3))
        XCTAssertFalse(follow.shouldShow(nil), "nothing playing: the list stays")
        follow.scrolled(byUser: false)
        XCTAssertTrue(follow.isFollowing, "the app's own scrolling changes nothing")
        follow.scrolled(byUser: true)
        XCTAssertFalse(follow.isFollowing)
        XCTAssertFalse(follow.shouldShow(3))
        follow.returned()
        XCTAssertTrue(follow.shouldShow(3))
    }

    func testTimestampsReadAsTheListShowsThem() {
        XCTAssertEqual(PhoneCaptionRow.timestamp(245.7), "4:05")
        XCTAssertEqual(PhoneCaptionRow.timestamp(3725), "1:02:05")
        XCTAssertEqual(PhoneCaptionRow.timestamp(-3), "0:00")
    }

    /// A row of three versions, and rows with one picked, for a look.
    func testTheVersionsStackAndAPickHidesTheOthers() throws {
        let captions = try versionsModel().captions
        func height(picked: String?) throws -> CGFloat {
            let renderer = ImageRenderer(
                content: PhoneCaptionRow(caption: captions[0], fontSize: 20, showFurigana: true, picked: picked, onTap: {})
                    .frame(width: 390)
            )
            return try XCTUnwrap(renderer.uiImage).size.height
        }
        XCTAssertGreaterThan(try height(picked: nil), try height(picked: "nemo") * 2, "three texts against one")
        let rows = VStack(alignment: .leading, spacing: 18) {
            PhoneCaptionRow(caption: captions[0], fontSize: 20, showFurigana: true, isCurrent: true, onTap: {})
            PhoneCaptionRow(caption: captions[1], fontSize: 20, showFurigana: true, picked: "nemo", onTap: {})
            PhoneCaptionRow(caption: captions[2], fontSize: 20, showFurigana: true, onTap: {})
        }
        .padding(16)
        .frame(width: 390)
        .background(Color(.systemBackground))
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let png = renderer.uiImage?.pngData() {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/phone-versions.png"))
        }
    }

    /// The rows as the screen draws them, rendered to a picture for a look
    /// (SNAPSHOT_DIR), and checked to have taken their room.
    func testTheRowsDrawWithReadingsAndTheLitOne() throws {
        let captions = PlaybackModel.captions(of: bundle)
        let rows = VStack(alignment: .leading, spacing: 18) {
            ForEach(captions) { caption in
                PhoneCaptionRow(caption: caption, fontSize: 20, showFurigana: true, isCurrent: caption.id == 1, onTap: {})
            }
            PhoneSplitter(seconds: 8, fontSize: 20)
        }
        .padding(16)
        .frame(width: 390)
        .background(Color(.systemBackground))
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 120, "two rows with readings, and the line")
        XCTAssertEqual(image.size.width, 390)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let png = image.pngData() {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/phone-captions.png"))
        }
    }
}
