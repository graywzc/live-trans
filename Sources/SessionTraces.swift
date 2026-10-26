import Foundation

/// Nothing of a session outlives the app: what was heard, looked up or
/// fetched lives in memory only. The network and the Jisho panel are kept
/// off the disk, and these are the folders macOS would fill for the app
/// anyway (URL and web caches, cookies), emptied at launch and at quit.
enum SessionTraces {
    static func folders(bundleID: String, library: URL, temporary: URL = FileManager.default.temporaryDirectory) -> [URL] {
        [
            // What macOS keeps of the windows to restore them, here or in
            // the temporary folder by macOS version.
            library.appending(path: "Saved Application State/\(bundleID).savedState"),
            temporary.appending(path: "\(bundleID).savedState"),
            library.appending(path: "Caches/\(bundleID)"),
            library.appending(path: "WebKit/\(bundleID)"),
            library.appending(path: "HTTPStorages/\(bundleID)"),
            library.appending(path: "HTTPStorages/\(bundleID).binarycookies"),
            library.appending(path: "Cookies/\(bundleID).binarycookies"),
        ]
    }

    static func erase(
        bundleID: String? = Bundle.main.bundleIdentifier,
        library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
        temporary: URL = FileManager.default.temporaryDirectory
    ) {
        guard let bundleID, !bundleID.isEmpty else { return }
        for folder in folders(bundleID: bundleID, library: library, temporary: temporary) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
