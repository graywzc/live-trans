import Foundation

/// What a caption is taken to be: one recognizer's text of it, or text
/// typed in place of them all when none heard it right, with its
/// translation once the host has given one.
enum Pick: Hashable, Sendable, ExpressibleByStringLiteral {
    case recognizer(String)
    case typed(String, english: String = "")

    /// What typed text is shown under, among the recognizers' names.
    static let typedName = "mine"
    /// Kept for a caption whose host-chosen version was taken back: every
    /// version shows, as a recognizer by this name has none.
    static let allName = "all"

    init(stringLiteral name: String) {
        self = .recognizer(name)
    }

    /// The recognizer's name, or `typedName`.
    var name: String {
        switch self {
        case .recognizer(let name): name
        case .typed: Self.typedName
        }
    }

    /// The typed text, when it is.
    var typedText: String? {
        if case .typed(let text, _) = self { text } else { nil }
    }

    /// As the host keeps it: a name, or the text with "en" when it has a
    /// translation (see phone_service.py).
    var record: Any {
        switch self {
        case .recognizer(let name): name
        case .typed(let text, let english): english.isEmpty ? ["ja": text] : ["ja": text, "en": english]
        }
    }

    init?(record: Any) {
        if let name = record as? String, !name.isEmpty {
            self = .recognizer(name)
        } else if let typed = record as? [String: String], let text = typed["ja"], !text.isEmpty {
            self = .typed(text, english: typed["en"] ?? "")
        } else {
            return nil
        }
    }
}

/// How an app reaches the host's record of a video's picks (see
/// phone_service.py): the two calls, so a test can stand in for them.
struct PickClient {
    /// The video's picks by place; nil when the host can't be reached.
    var load: () async -> [Int: Pick]?
    /// One change, nil taking a pick back; whether the host has it. Typed
    /// text goes without its translation, which the host makes.
    var send: (_ place: Int, _ pick: Pick?) async -> Bool

    /// Where a caption is in the record: its start in milliseconds, which
    /// holds however a video's lines are numbered.
    static func place(of seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    static let port = 8773

    /// The service on `host`, the machine bundles and captions come from,
    /// on either app's tailnet. Typed text is translated into `language`.
    static func over(host: URL?, video: String, language: String = "zh") -> PickClient? {
        guard let host = serviceURL(host), let url = URL(string: "picks/\(video)", relativeTo: host) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        return PickClient {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let picks = body["picks"] as? [String: Any]
            else { return nil }
            return Dictionary(uniqueKeysWithValues: picks.compactMap { key, record in
                Int(key).flatMap { place in Pick(record: record).map { (place, $0) } }
            })
        } send: { place, pick in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            // Typed text is translated before the host answers, and the
            // translator may have to load its model first.
            request.timeoutInterval = pick?.typedText == nil ? 5 : 75
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Null, which takes the pick back, rather than left out.
            let change: Any = switch pick {
            case nil: NSNull()
            case .recognizer(let name): name
            case .typed(let text, _): ["ja": text, "to": language]
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["at": place, "pick": change]) else { return false }
            request.httpBody = body
            guard let (_, response) = try? await session.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 204
        }
    }

    /// Where the service on `host` answers; nil for a host it can't be on.
    static func serviceURL(_ host: URL?) -> URL? {
        guard let host, let name = host.host(), let scheme = host.scheme, scheme != "file" else { return nil }
        return URL(string: "http://\(name):\(port)/")
    }
}

/// Typed text translated by the host's service, kept nowhere: Incognito's,
/// whose picks are in memory alone.
struct TypedTranslator {
    /// The translation; nil when there is none to be had.
    var translate: (_ japanese: String) async -> String?

    static func over(host: URL?, language: String) -> TypedTranslator? {
        guard let url = PickClient.serviceURL(host).flatMap({ URL(string: "translate", relativeTo: $0) }) else {
            return nil
        }
        let session = URLSession(configuration: .ephemeral)
        return TypedTranslator { japanese in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 75
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["ja": japanese, "to": language])
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return body["en"] as? String
        }
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
    var onChange: (([Int: Pick]) -> Void)?
    private(set) var picks: [Int: Pick]

    private let client: PickClient?
    private let defaults: UserDefaults?
    /// The host's record, as last read.
    private var record: [Int: Pick]
    /// Changes not yet sent, nil taking a pick back.
    private var waiting: [Int: Pick?]
    private var isSending = false

    init(video: String, client: PickClient?, defaults: UserDefaults? = nil) {
        self.video = video
        self.client = client
        self.defaults = defaults
        record = Self.read(Self.recordKey(for: video), from: defaults).compactMapValues { $0 }
        waiting = Self.read(Self.waitingKey(for: video), from: defaults)
        picks = Self.merged(record, waiting)
    }

    /// `pick` is the caption's at `place`; nil takes the pick back.
    func pick(_ pick: Pick?, at place: Int) {
        waiting[place] = .some(pick)
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

    /// One change at a time, the last made for a place going last. Typed
    /// text sent, the host's record is read for its translation.
    private func send() async {
        guard let client, !isSending else { return }
        isSending = true
        var typed = false
        while let (place, change) = waiting.first {
            guard await client.send(place, change) else { break }
            record[place] = change
            if waiting[place] == change { waiting.removeValue(forKey: place) }
            typed = typed || change?.typedText != nil
            changed()
        }
        isSending = false
        if typed, waiting.isEmpty, let found = await client.load(), waiting.isEmpty {
            record = found
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

    private static func merged(_ record: [Int: Pick], _ waiting: [Int: Pick?]) -> [Int: Pick] {
        var picks = record
        for (place, change) in waiting { picks[place] = change }
        return picks
    }

    // MARK: On the phone

    private static func recordKey(for video: String) -> String { "picks.\(video)" }
    private static func waitingKey(for video: String) -> String { "picks.waiting.\(video)" }

    /// As the host keeps them, "" for a pick taken back.
    private func save() {
        defaults?.set(Self.records(record.mapValues(Optional.some)), forKey: Self.recordKey(for: video))
        defaults?.set(Self.records(waiting), forKey: Self.waitingKey(for: video))
    }

    private static func records(_ picks: [Int: Pick?]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: picks.map { (String($0.key), $0.value?.record ?? "") })
    }

    private static func read(_ key: String, from defaults: UserDefaults?) -> [Int: Pick?] {
        guard let saved = defaults?.dictionary(forKey: key) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, record in
            Int(key).map { ($0, Pick(record: record)) }
        })
    }

    /// The phone's copy gone with the video; the host's record stays, for
    /// the Mac and for the next download.
    static func forget(_ video: String, in defaults: UserDefaults) {
        defaults.removeObject(forKey: recordKey(for: video))
        defaults.removeObject(forKey: waitingKey(for: video))
    }
}
