import SwiftUI
import XCTest
@testable import LiveTransMobile

/// The player's model and rows: the captions made of a bundle, which one
/// is lit as the video moves, a sentence played again, the list following
/// or staying, and where the video was left.
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
