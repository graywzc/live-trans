import Foundation

/// Nothing of a session outlives the app: what was heard, looked up or
/// fetched lives in memory only. The network and the Jisho panel are kept
/// off the disk, and these are the folders macOS would fill for the app
/// anyway (URL and web caches, cookies), emptied at launch and at quit.
enum SessionTraces {
    static func folders(bundleID: String, library: URL) -> [URL] {
        [
            library.appending(path: "Caches/\(bundleID)"),
            library.appending(path: "WebKit/\(bundleID)"),
            library.appending(path: "HTTPStorages/\(bundleID)"),
            library.appending(path: "HTTPStorages/\(bundleID).binarycookies"),
            library.appending(path: "Cookies/\(bundleID).binarycookies"),
        ]
    }

    static func erase(
        bundleID: String? = Bundle.main.bundleIdentifier,
        library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    ) {
        guard let bundleID, !bundleID.isEmpty else { return }
        for folder in folders(bundleID: bundleID, library: library) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
