import XCTest
@testable import LiveTransMobile

/// The store against a host that is a folder on disk: the files the host
/// serves, fetched over `file://` the way they are over HTTPS.
@MainActor
final class BundleStoreTests: XCTestCase {
    private var folder: URL!
    private var host: URL!
    private var root: URL!

    override func setUp() async throws {
        folder = URL.temporaryDirectory.appending(path: "BundleStoreTests-\(UUID().uuidString)")
        host = folder.appending(path: "host")
        root = folder.appending(path: "bundles")
        try serve("0123456789abcdef", Fixtures.bundle, videoBytes: 4096)
        try serve("fedcba9876543210", Fixtures.untitledBundle, videoBytes: 2048)
        try Data(Fixtures.index.utf8).write(to: host.appending(path: "index.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func serve(_ id: String, _ bundle: String, videoBytes: Int) throws {
        let folder = host.appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bundle.utf8).write(to: folder.appending(path: "bundle.json"))
        try Data(repeating: 7, count: videoBytes).write(to: folder.appending(path: "video.mp4"))
    }

    private func store(host: URL?) -> BundleStore {
        BundleStore(host: host, root: root, configuration: .ephemeral)
    }

    private func wait(
        _ what: String, timeout: TimeInterval = 10, until condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testTheHostsBundlesAreListedNewestFirst() async {
        let store = store(host: host)
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.items.map(\.name), ["Lesson one", "fedcba9876543210"])
        XCTAssertEqual(store.items.map(\.isDownloaded), [false, false])
        XCTAssertEqual(store.items.map(\.size), [4096, 2048])
        XCTAssertEqual(store.items.map(\.lines), [2, nil])
        XCTAssertTrue(store.downloads.isEmpty)
    }

    func testADownloadPutsTheBundleOnThePhone() async throws {
        let store = store(host: host)
        await store.refresh()
        store.download("0123456789abcdef")
        XCTAssertEqual(store.downloads["0123456789abcdef"], BundleStore.Download(written: 0, expected: 4096))
        try await wait("the download") { store.items[0].isDownloaded }
        XCTAssertNil(store.downloads["0123456789abcdef"])
        XCTAssertNil(store.error)
        let copy = root.appending(path: "0123456789abcdef")
        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "video.mp4")).count, 4096)
        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "bundle.json")), Data(Fixtures.bundle.utf8))
        XCTAssertEqual(store.bundle("0123456789abcdef")?.lines.count, 2)
        XCTAssertNil(store.bundle("fedcba9876543210"))
        // Nothing else landed on the phone.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["0123456789abcdef"])

        // The next launch finds it, host or no host.
        let later = self.store(host: nil)
        await later.refresh()
        XCTAssertEqual(later.items.map(\.name), ["Lesson one"])
        XCTAssertEqual(later.items.map(\.isDownloaded), [true])
        XCTAssertEqual(later.items.map(\.lines), [2])
        XCTAssertEqual(later.bundle("0123456789abcdef")?.name, "Lesson one")
        XCTAssertEqual(later.error, "Set the host in Settings to see its bundles.")
    }

    func testDeletingTakesTheBundleOffThePhone() async throws {
        let store = store(host: host)
        await store.refresh()
        store.download("fedcba9876543210")
        try await wait("the download") { store.items[1].isDownloaded }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "fedcba9876543210").path))

        store.delete("fedcba9876543210")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "fedcba9876543210").path))
        XCTAssertEqual(store.items.map(\.isDownloaded), [false, false])
        XCTAssertNil(store.bundle("fedcba9876543210"))
        // Still on the host's list, to be downloaded again.
        XCTAssertEqual(store.items.map(\.name), ["Lesson one", "fedcba9876543210"])
    }

    func testAHostThatCannotBeReachedIsSaidAndThePhonesBundlesStand() async throws {
        let store = store(host: host)
        await store.refresh()
        store.download("0123456789abcdef")
        try await wait("the download") { store.items[0].isDownloaded }

        store.host = folder.appending(path: "nowhere")
        await store.refresh()
        XCTAssertEqual(store.error?.hasPrefix("Could not reach "), true, store.error ?? "")
        XCTAssertEqual(store.items.map(\.name), ["Lesson one"])
        XCTAssertEqual(store.items.map(\.isDownloaded), [true])

        // Back in reach, the error goes.
        store.host = host
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.items.map(\.name), ["Lesson one", "fedcba9876543210"])
    }

    func testABundleThatIsNotThereFailsAndLeavesNothing() async throws {
        let store = store(host: host)
        await store.refresh()
        try FileManager.default.removeItem(at: host.appending(path: "0123456789abcdef/video.mp4"))
        store.download("0123456789abcdef")
        try await wait("the failure") { store.error != nil }
        XCTAssertEqual(store.error?.hasPrefix("Downloading video.mp4 of Lesson one failed: "), true, store.error ?? "")
        XCTAssertNil(store.downloads["0123456789abcdef"])
        // The bundle may land after the video failed; it goes too.
        let copy = root.appending(path: "0123456789abcdef")
        try await wait("the folder to go") { !FileManager.default.fileExists(atPath: copy.path) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(store.items.map(\.isDownloaded), [false, false])
    }

    func testABundleOfAnotherVersionIsNotKept() async throws {
        let later = Fixtures.bundle.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        try Data(later.utf8).write(to: host.appending(path: "0123456789abcdef/bundle.json"))
        let store = store(host: host)
        await store.refresh()
        store.download("0123456789abcdef")
        try await wait("the failure") { store.error != nil }
        XCTAssertEqual(
            store.error,
            "Downloading bundle.json of Lesson one failed: The bundle is version 2; this app reads version 1."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "0123456789abcdef").path))
    }
}
