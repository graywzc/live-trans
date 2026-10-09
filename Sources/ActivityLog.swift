import Foundation
import Observation

/// What the GPU server has logged since it was last asked.
struct HostEvents: Decodable, Equatable {
    struct Event: Decodable, Equatable {
        var seq: Int
        /// Seconds since 1970, by the server's clock.
        var at: Double
        var text: String
        /// A step of a hearing rather than a line of the server's log.
        var detail: Bool?
    }

    /// Names the run of the server: one started since numbers its lines
    /// from one again.
    var boot: String
    /// Where to ask from next time.
    var next: Int
    var events: [Event]
}

/// What goes on behind the captions, on this Mac and on the GPU server, as
/// one list in the order it happened: the lines the app would print, and
/// the server's log, asked for every second while there is a server. Among
/// them, marked as details, the steps of each hearing: where an utterance
/// was cut and why, what Whisper was given and heard, each cut made or
/// refused. Like everything else of a session it is in memory only.
@MainActor
@Observable
final class ActivityLog {
    enum Machine: Equatable {
        case mac
        case host
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let at: Date
        let machine: Machine
        let text: String
        var isDetail = false
    }

    static let shared = ActivityLog()
    /// The oldest lines are let go past this many.
    static let kept = 5000
    static let pollInterval: TimeInterval = 1

    private(set) var entries: [Entry] = []
    /// Whether the steps are listed among the rest.
    var showsDetails = true

    private var nextID = 0
    private var boot: String?
    /// The server's line to ask from.
    private(set) var since = 0
    private var poll: Task<Void, Never>?

    /// A line for stdout, as before, and for the list. From any thread.
    nonisolated static func note(_ text: String, detail: Bool = false) {
        print(text)
        let at = Date()
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.record(text, at: at, detail: detail) }
        } else {
            Task { @MainActor in shared.record(text, at: at, detail: detail) }
        }
    }

    /// A step, listed with the details.
    nonisolated static func detail(_ text: String) {
        note(text, detail: true)
    }

    /// What the list shows: all of it, or the lines without the steps.
    var shown: [Entry] {
        showsDetails ? entries : entries.filter { !$0.isDetail }
    }

    /// Puts the line where its time is: the server's lines arrive up to a
    /// second after the Mac's of the same moment.
    func record(_ text: String, from machine: Machine = .mac, at: Date = Date(), detail: Bool = false) {
        let index = entries.lastIndex { $0.at <= at }.map { $0 + 1 } ?? 0
        entries.insert(Entry(id: nextID, at: at, machine: machine, text: text, isDetail: detail), at: index)
        nextID += 1
        if entries.count > Self.kept {
            entries.removeFirst(entries.count - Self.kept)
        }
    }

    /// The server's answer to being asked from `since`. One from a server
    /// started since the last answer was counted from the wrong place, and
    /// is asked for again from the top.
    func take(_ answer: HostEvents) {
        if answer.boot != boot, since > 0 {
            boot = answer.boot
            since = 0
            return
        }
        boot = answer.boot
        since = answer.next
        for event in answer.events {
            record(event.text, from: .host, at: Date(timeIntervalSince1970: event.at), detail: event.detail ?? false)
        }
    }

    func clear() {
        entries = []
    }

    /// Asks the server for its lines for as long as the app runs, whenever
    /// `client` has one to ask.
    func follow(_ client: @escaping @MainActor () -> ASRClient?) {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let client = client(), let answer = try? await client.events(since: self.since) {
                    self.take(answer)
                }
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }
}
