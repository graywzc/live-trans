import Foundation

/// How an app reaches the host's record of a video's picks (see
/// phone_service.py): the two calls, so a test can stand in for them.
struct PickClient {
    /// The video's picks by place; nil when the host can't be reached.
    var load: () async -> [Int: String]?
    /// One change, nil taking a pick back; whether the host has it.
    var send: (_ place: Int, _ pick: String?) async -> Bool

    /// Where a caption is in the record: its start in milliseconds, which
    /// holds however a video's lines are numbered.
    static func place(of seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static let port = 8773

    /// The service on `host`, the machine bundles and captions come from,
    /// on either app's tailnet.
    static func over(host: URL?, video: String) -> PickClient? {
        guard let host, let name = host.host(), let scheme = host.scheme, scheme != "file",
              let url = URL(string: "http://\(name):\(port)/picks/\(video)")
        else { return nil }
        let session = URLSession(configuration: .ephemeral)
        return PickClient {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONDecoder().decode([String: [String: String]].self, from: data),
                  let picks = body["picks"]
            else { return nil }
            return Dictionary(uniqueKeysWithValues: picks.compactMap { key, name in Int(key).map { ($0, name) } })
        } send: { place, pick in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let body = try? JSONEncoder().encode(Change(at: place, pick: pick)) else { return false }
            request.httpBody = body
            guard let (_, response) = try? await session.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 204
        }
    }

    private struct Change: Encodable {
        let at: Int
        let pick: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(at, forKey: .at)
            // Null, which takes the pick back, rather than left out.
            try container.encode(pick, forKey: .pick)
        }

        enum CodingKeys: String, CodingKey { case at, pick }
    }
}

/// A video's picks in one app: the host's record, the only one that
/// counts, with this app's changes on top until the host has them. Each
/// is sent as it is made; one that can't be, at the gym, waits for the
/// next `refresh`. With `defaults` the phone keeps both, to work with the
/// host out of reach; the Mac keeps nothing.
@MainActor
final class PickBook {
    let video: String
    /// Told the picks whenever they change.
    var onChange: (([Int: String]) -> Void)?
    private(set) var picks: [Int: String]

    private let client: PickClient?
    private let defaults: UserDefaults?
    /// The host's record, as last read.
    private var record: [Int: String]
    /// Changes not yet sent, "" taking a pick back.
    private var waiting: [Int: String]
    private var isSending = false

    init(video: String, client: PickClient?, defaults: UserDefaults? = nil) {
        self.video = video
        self.client = client
        self.defaults = defaults
        record = Self.read(Self.recordKey(for: video), from: defaults)
        waiting = Self.read(Self.waitingKey(for: video), from: defaults)
        picks = Self.merged(record, waiting)
    }

    /// `name`'s text is the caption's at `place`; nil takes the pick back.
    func pick(_ name: String?, at place: Int) {
        waiting[place] = name ?? ""
        changed()
        Task { await send() }
    }

    /// Sends what is waiting, then reads the host's record.
    func refresh() async {
        await send()
        guard let client, waiting.isEmpty, let found = await client.load() else { return }
        // Picked meanwhile: that one is on its way, and stays on top.
        record = found
        changed()
    }

    /// One change at a time, the last made for a place going last.
    private func send() async {
        guard let client, !isSending else { return }
        isSending = true
        defer { isSending = false }
        while let (place, change) = waiting.first {
            guard await client.send(place, change.isEmpty ? nil : change) else { return }
            record[place] = change.isEmpty ? nil : change
            if waiting[place] == change { waiting[place] = nil }
            changed()
        }
    }

    private func changed() {
        let merged = Self.merged(record, waiting)
        save()
        if merged != picks {
            picks = merged
            onChange?(merged)
        }
    }

    private static func merged(_ record: [Int: String], _ waiting: [Int: String]) -> [Int: String] {
        var picks = record
        for (place, change) in waiting { picks[place] = change.isEmpty ? nil : change }
        return picks
    }

    // MARK: On the phone

    private static func recordKey(for video: String) -> String { "picks.\(video)" }
    private static func waitingKey(for video: String) -> String { "picks.waiting.\(video)" }

    private func save() {
        defaults?.set(Self.strings(record), forKey: Self.recordKey(for: video))
        defaults?.set(Self.strings(waiting), forKey: Self.waitingKey(for: video))
    }

    private static func strings(_ picks: [Int: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: picks.map { (String($0.key), $0.value) })
    }

    private static func read(_ key: String, from defaults: UserDefaults?) -> [Int: String] {
        guard let saved = defaults?.dictionary(forKey: key) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, name in Int(key).map { ($0, name) } })
    }

    /// The phone's copy gone with the video; the host's record stays, for
    /// the Mac and for the next download.
    static func forget(_ video: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: recordKey(for: video))
        defaults.removeObject(forKey: waitingKey(for: video))
    }
}
