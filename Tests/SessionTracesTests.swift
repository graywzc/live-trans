import XCTest
@testable import LiveTrans

final class SessionTracesTests: XCTestCase {
    func testTheAppsCachesAndCookiesAreErasedAndNothingElse() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let manager = FileManager.default
        let kept = [library.appending(path: "Caches/com.other.app"), library.appending(path: "Preferences")]
        for folder in SessionTraces.folders(bundleID: "com.example.livetrans", library: library) + kept {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("heard".utf8).write(to: folder.appending(path: "Cache.db"))
        }

        SessionTraces.erase(bundleID: "com.example.livetrans", library: library)

        for folder in SessionTraces.folders(bundleID: "com.example.livetrans", library: library) {
            XCTAssertFalse(manager.fileExists(atPath: folder.path), folder.path)
        }
        for folder in kept {
            XCTAssertTrue(manager.fileExists(atPath: folder.path), folder.path)
        }
    }

    func testTheNetworkKeepsNothingOnDisk() {
        let session = ASRClient(baseURL: URL(string: "http://localhost:1")!).session
        XCTAssertNil(session.configuration.urlCache?.diskCapacity.nonZero)
        XCTAssertFalse(session.configuration.httpCookieStorage === HTTPCookieStorage.shared)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
