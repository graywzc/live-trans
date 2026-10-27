import Foundation
import Observation

/// What the Library shows and does: the bundles the host lists, the ones
/// on the phone, the downloads under way, and their deletion.
///
/// A downloaded bundle is the folder `<root>/<id>/` holding `bundle.json`
/// and `video.mp4`; a folder missing either is not one, and is downloaded
/// again. Nothing else is written: the host's list is held in memory.
@MainActor
@Observable
final class BundleStore {
    static let bundleName = "bundle.json"
    static let videoName = "video.mp4"

    /// A bundle as the list shows it: from the host's index, or from the
    /// phone's copy when the host does not list it or cannot be reached.
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String?
        let duration: Double
        let created: String
        let size: Int64
        /// How many captions, when known.
        let lines: Int?
        var isDownloaded: Bool

        var name: String { BundleNaming.name(title: title, id: id) }
    }

    /// A download under way: the video's bytes, the bundle being small.
    struct Download: Equatable {
        var written: Int64 = 0
        /// From the index until the host says.
        var expected: Int64

        var fraction: Double {
            expected > 0 ? min(Double(written) / Double(expected), 1) : 0
        }
    }

    private(set) var items: [Item] = []
    private(set) var downloads: [String: Download] = [:]
    /// Why the last thing asked of the host did not happen, until the next
    /// does.
    private(set) var error: String?
    private(set) var isRefreshing = false

    /// The folder the host serves: `index.json` and a folder per bundle.
    var host: URL?
    /// Where the bundles go on the phone.
    let root: URL

    private var remote: [BundleSummary] = []
    private var local: [String: VideoBundle] = [:]
    /// Downloads given up on, whose other file may still land: it goes.
    private var discarded: Set<String> = []
    /// Carries the downloads: in the app a background session, which goes on
    /// when the app is put away and hands the files over when it is back.
    private let session: URLSession
    private let delegate: BundleDownloadDelegate
    /// For the index: a fetch with nothing kept.
    private let fetchSession = URLSession(configuration: .ephemeral)

    static var documentsRoot: URL {
        URL.documentsDirectory.appending(path: "bundles")
    }

    static var backgroundConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.larrywang.livetrans.ios.bundles")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }

    init(host: URL?, root: URL, configuration: URLSessionConfiguration) {
        self.host = host
        self.root = root
        delegate = BundleDownloadDelegate(root: root)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.store = self
        scanLocal()
        rebuild()
        // Downloads a background session went on with after the app quit.
        session.getAllTasks { tasks in
            let running = tasks.compactMap { task -> (String, Download)? in
                guard let parts = BundleDownloadDelegate.parts(of: task), parts.name == Self.videoName,
                      task.state == .running || task.state == .suspended
                else { return nil }
                return (parts.id, Download(written: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (id, download) in running where self.downloads[id] == nil { self.downloads[id] = download }
            }
        }
    }

    /// The bundle on the phone, for playing.
    func bundle(_ id: String) -> VideoBundle? {
        local[id]
    }

    /// Asks the host for its list. Without an answer the list stands, with
    /// the bundles on the phone in it, and the error says why.
    func refresh() async {
        guard !isRefreshing else { return }
        guard let host else {
            error = "Set the host in Settings to see its bundles."
            remote = []
            rebuild()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await fetchSession.data(from: host.appending(path: "index.json"))
            remote = try Self.index(from: data, status: (response as? HTTPURLResponse)?.statusCode)
            error = nil
        } catch {
            self.error = "Could not reach \(Self.describe(host)): \(error.localizedDescription)"
        }
        rebuild()
    }

    /// Fetches the bundle and its video into the bundle's folder.
    func download(_ id: String) {
        guard let host, downloads[id] == nil, Self.isSafeID(id) else { return }
        discarded.remove(id)
        downloads[id] = Download(expected: remote.first { $0.id == id }?.size ?? 0)
        for name in [Self.bundleName, Self.videoName] {
            let task = session.downloadTask(with: host.appending(path: id).appending(path: name))
            task.taskDescription = BundleDownloadDelegate.description(id: id, name: name)
            task.resume()
        }
    }

    /// Removes the bundle from the phone, or stops its download.
    func delete(_ id: String) {
        guard Self.isSafeID(id) else { return }
        cancelTasks(for: id)
        if downloads[id] != nil { discarded.insert(id) }
        downloads[id] = nil
        local[id] = nil
        try? FileManager.default.removeItem(at: root.appending(path: id))
        rebuild()
    }

    // MARK: The download session's word, on the main actor

    func progressed(_ id: String, written: Int64, expected: Int64) {
        guard downloads[id] != nil else { return }
        downloads[id]?.written = written
        if expected > 0 { downloads[id]?.expected = expected }
    }

    /// One of the two files is in place; the bundle is downloaded once both
    /// are and the bundle reads.
    func finished(_ id: String) {
        let folder = root.appending(path: id)
        if discarded.contains(id) {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let json = folder.appending(path: Self.bundleName)
        guard FileManager.default.fileExists(atPath: json.path),
              FileManager.default.fileExists(atPath: folder.appending(path: Self.videoName).path)
        else { return }
        do {
            local[id] = try VideoBundle.decode(try Data(contentsOf: json))
            downloads[id] = nil
            rebuild()
        } catch {
            failed(id, name: Self.bundleName, message: error.localizedDescription)
        }
    }

    /// Nothing of a download that failed stays: half a bundle is no use.
    func failed(_ id: String, name: String, message: String) {
        cancelTasks(for: id)
        discarded.insert(id)
        downloads[id] = nil
        local[id] = nil
        try? FileManager.default.removeItem(at: root.appending(path: id))
        error = "Downloading \(name) of \(items.first { $0.id == id }?.name ?? id) failed: \(message)"
        rebuild()
    }

    // MARK: -

    private func cancelTasks(for id: String) {
        session.getAllTasks { tasks in
            for task in tasks where BundleDownloadDelegate.parts(of: task)?.id == id {
                task.cancel()
            }
        }
    }

    /// The bundles on the phone, by their folders.
    private func scanLocal() {
        local = [:]
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let bundle = Self.load(folder) else { continue }
            local[folder.lastPathComponent] = bundle
        }
    }

    /// The host's answer for `index.json`: its bundles; none when it has
    /// none, as it then removes the file and answers 404; or why not.
    nonisolated static func index(from data: Data, status: Int?) throws -> [BundleSummary] {
        if status == 404 { return [] }
        if let status, !(200..<300).contains(status) { throw BundleError.badStatus(status) }
        return try BundleSummary.decodeIndex(data)
    }

    /// The bundle in the folder, if it is whole and reads.
    nonisolated static func load(_ folder: URL) -> VideoBundle? {
        guard FileManager.default.fileExists(atPath: folder.appending(path: videoName).path),
              let data = try? Data(contentsOf: folder.appending(path: bundleName))
        else { return nil }
        return try? VideoBundle.decode(data)
    }

    /// The host's list first, then what is on the phone that it does not
    /// list; newest first.
    private func rebuild() {
        var byID: [String: Item] = [:]
        for summary in remote {
            byID[summary.id] = Item(
                id: summary.id, title: summary.title, duration: summary.duration, created: summary.created,
                size: summary.size, lines: summary.lines, isDownloaded: local[summary.id] != nil
            )
        }
        for (id, bundle) in local where byID[id] == nil {
            byID[id] = Item(
                id: id, title: bundle.title, duration: bundle.duration, created: bundle.created, size: bundle.size,
                lines: bundle.lines.count, isDownloaded: true
            )
        }
        items = byID.values.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    /// An id is a folder name under the root and a path on the host: one
    /// that would lead anywhere else is not followed.
    nonisolated static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
    }

    private static func describe(_ host: URL) -> String {
        host.host() ?? host.absoluteString
    }
}

/// The download session's delegate, off the main actor as the session
/// calls it: moves each finished file into its bundle's folder before the
/// system deletes it, and tells the store on the main actor.
final class BundleDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var store: BundleStore?
    let root: URL
    /// Bytes last reported, by task: a long video would otherwise report a
    /// few thousand times.
    private var reported: [Int: Int64] = [:]

    init(root: URL) {
        self.root = root
    }

    static func description(id: String, name: String) -> String {
        "\(id)/\(name)"
    }

    /// Which bundle and file a task is fetching, from its description.
    static func parts(of task: URLSessionTask) -> (id: String, name: String)? {
        guard let description = task.taskDescription, let slash = description.firstIndex(of: "/") else { return nil }
        return (String(description[..<slash]), String(description[description.index(after: slash)...]))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let parts = Self.parts(of: downloadTask), parts.name == BundleStore.videoName else { return }
        let step = max(totalBytesExpectedToWrite / 200, 1 << 16)
        guard totalBytesWritten - (reported[downloadTask.taskIdentifier] ?? 0) >= step else { return }
        reported[downloadTask.taskIdentifier] = totalBytesWritten
        Task { @MainActor [store] in
            store?.progressed(parts.id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parts = Self.parts(of: downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor [store] in
                store?.failed(parts.id, name: parts.name, message: BundleError.badStatus(http.statusCode).localizedDescription)
            }
            return
        }
        let destination = root.appending(path: parts.id).appending(path: parts.name)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor [store] in store?.failed(parts.id, name: parts.name, message: error.localizedDescription) }
            return
        }
        Task { @MainActor [store] in store?.finished(parts.id) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        reported[task.taskIdentifier] = nil
        guard let error, let parts = Self.parts(of: task) else { return }
        // Cancelled by the store, which has already forgotten it.
        if (error as? URLError)?.code == .cancelled { return }
        Task { @MainActor [store] in store?.failed(parts.id, name: parts.name, message: error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in BackgroundTransfer.finish() }
    }
}
