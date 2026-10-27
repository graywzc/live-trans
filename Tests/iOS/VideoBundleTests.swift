import XCTest
@testable import LiveTransMobile

final class VideoBundleTests: XCTestCase {
    func testABundleIsReadAsTheHostWritesIt() throws {
        let bundle = try VideoBundle.decode(Data(Fixtures.bundle.utf8))
        XCTAssertEqual(bundle.id, "0123456789abcdef")
        XCTAssertEqual(bundle.name, "Lesson one")
        XCTAssertEqual(bundle.duration, 95.5)
        XCTAssertEqual(bundle.created, "2026-10-27T18:00:00Z")
        XCTAssertEqual(bundle.video, "video.mp4")
        XCTAssertEqual(bundle.size, 4096)
        XCTAssertEqual(bundle.step, "speech-mean")
        XCTAssertEqual(bundle.lines, [
            VideoBundle.Line(ja: "窓の外で鳥が歌っている。", en: "A bird is singing outside the window.", start: 1.2, end: 3.8),
            VideoBundle.Line(ja: "お茶を一杯いかがですか。", en: "Would you like a cup of tea?", start: 4.5, end: 6.9),
        ])
    }

    func testABundleWithoutATitleGoesByItsID() throws {
        let bundle = try VideoBundle.decode(Data(Fixtures.untitledBundle.utf8))
        XCTAssertNil(bundle.title)
        XCTAssertEqual(bundle.name, "fedcba9876543210")
        XCTAssertNil(bundle.step)
    }

    func testAnotherVersionIsRefused() {
        let later = Fixtures.bundle.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        XCTAssertThrowsError(try VideoBundle.decode(Data(later.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "The bundle is version 2; this app reads version 1.")
        }
        XCTAssertThrowsError(try VideoBundle.decode(Data("{\"lines\": []}".utf8)))
    }

    func testTheIndexListsEachBundle() throws {
        let index = try BundleSummary.decodeIndex(Data(Fixtures.index.utf8))
        XCTAssertEqual(index.map(\.name), ["Lesson one", "fedcba9876543210"])
        XCTAssertEqual(index.map(\.size), [4096, 2048])
        XCTAssertEqual(index.map(\.lines), [2, nil])
        XCTAssertEqual(index[1].duration, 40)
        XCTAssertEqual(index[1].created, "2026-10-26T09:30:00Z")
    }

    func testAHostWithNoBundlesHasNoIndexToGive() throws {
        XCTAssertEqual(try BundleStore.index(from: Data("not found".utf8), status: 404), [])
        XCTAssertEqual(try BundleStore.index(from: Data(Fixtures.index.utf8), status: 200).count, 2)
        XCTAssertEqual(try BundleStore.index(from: Data(Fixtures.index.utf8), status: nil).count, 2)
        XCTAssertThrowsError(try BundleStore.index(from: Data(), status: 500)) { error in
            XCTAssertEqual(error.localizedDescription, "The host answered HTTP 500.")
        }
        XCTAssertThrowsError(try BundleStore.index(from: Data("<html>".utf8), status: 200))
    }

    func testLengthsAndSizesReadAsTheListShowsThem() {
        XCTAssertEqual(BundleNaming.length(95.5), "1:36")
        XCTAssertEqual(BundleNaming.length(3661), "1:01:01")
        XCTAssertEqual(BundleNaming.length(0), "0:00")
        XCTAssertEqual(BundleNaming.name(title: "  ", id: "abc"), "abc")
        XCTAssertEqual(BundleNaming.name(title: " A title ", id: "abc"), "A title")
        XCTAssertTrue(BundleNaming.size(204_764_013).contains("MB"))
    }

    func testTheHostIsAURLThatCouldBeReached() {
        XCTAssertEqual(AppSettings.hostURL(" https://host.example/livetrans \n")?.absoluteString, "https://host.example/livetrans")
        XCTAssertEqual(AppSettings.hostURL("http://host.example:8080")?.absoluteString, "http://host.example:8080")
        XCTAssertEqual(AppSettings.hostURL("file:///tmp/host")?.absoluteString, "file:///tmp/host")
        XCTAssertNil(AppSettings.hostURL(""))
        XCTAssertNil(AppSettings.hostURL("host.example/livetrans"))
        XCTAssertNil(AppSettings.hostURL("https://"))
        XCTAssertNil(AppSettings.hostURL("ftp://host.example"))
    }

    func testAnIDIsAFolderNameAndNothingMore() {
        XCTAssertTrue(BundleStore.isSafeID("0123456789abcdef"))
        XCTAssertFalse(BundleStore.isSafeID(""))
        XCTAssertFalse(BundleStore.isSafeID(".."))
        XCTAssertFalse(BundleStore.isSafeID("../elsewhere"))
        XCTAssertFalse(BundleStore.isSafeID("a/b"))
    }
}

/// Bundles as the host writes them, with sentences made up for the tests.
enum Fixtures {
    static let bundle = """
        {"version": 1, "id": "0123456789abcdef", "title": "Lesson one", "duration": 95.5,
         "created": "2026-10-27T18:00:00Z", "video": "video.mp4", "size": 4096, "step": "speech-mean",
         "lines": [
           {"ja": "窓の外で鳥が歌っている。", "en": "A bird is singing outside the window.", "start": 1.2, "end": 3.8},
           {"ja": "お茶を一杯いかがですか。", "en": "Would you like a cup of tea?", "start": 4.5, "end": 6.9}
         ]}
        """

    static let untitledBundle = """
        {"version": 1, "id": "fedcba9876543210", "duration": 40, "created": "2026-10-26T09:30:00Z",
         "video": "video.mp4", "size": 2048,
         "lines": [{"ja": "明日は図書館に行きます。", "en": "I will go to the library tomorrow.", "start": 0.5, "end": 2.5}]}
        """

    static let index = """
        [{"id": "0123456789abcdef", "title": "Lesson one", "duration": 95.5, "created": "2026-10-27T18:00:00Z", "size": 4096,
          "lines": 2},
         {"id": "fedcba9876543210", "title": null, "duration": 40, "created": "2026-10-26T09:30:00Z", "size": 2048}]
        """
}
