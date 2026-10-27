import Foundation

/// A video with its captions, as the host writes it for the phone:
/// `bundle.json` beside `video.mp4` in the host's dev cache, and the
/// phone's copy of both under `Documents/bundles/<id>/`.
struct VideoBundle: Decodable, Equatable, Identifiable {
    struct Line: Decodable, Equatable {
        let ja: String
        let en: String
        let start: Double
        let end: Double
    }

    /// The one format this app reads.
    static let supportedVersion = 1

    let version: Int
    let id: String
    /// The tab's title when the Mac gave one.
    let title: String?
    let duration: Double
    /// When the host wrote it, ISO 8601.
    let created: String
    /// The video's file name beside the bundle.
    let video: String
    /// The video's size in bytes.
    let size: Int64
    /// The dev step whose captions these are.
    let step: String?
    let lines: [Line]

    var name: String { BundleNaming.name(title: title, id: id) }

    /// The bundle as the host wrote it, or why it cannot be read.
    static func decode(_ data: Data) throws -> VideoBundle {
        let bundle = try JSONDecoder().decode(VideoBundle.self, from: data)
        guard bundle.version == supportedVersion else { throw BundleError.unsupportedVersion(bundle.version) }
        return bundle
    }
}

/// One line of the host's `index.json`: a bundle whose video is complete.
struct BundleSummary: Decodable, Equatable, Identifiable {
    let id: String
    let title: String?
    let duration: Double
    let created: String
    let size: Int64
    /// How many captions.
    let lines: Int?

    var name: String { BundleNaming.name(title: title, id: id) }

    static func decodeIndex(_ data: Data) throws -> [BundleSummary] {
        try JSONDecoder().decode([BundleSummary].self, from: data)
    }
}

enum BundleNaming {
    /// The title, or the id of a bundle the Mac gave no title.
    static func name(title: String?, id: String) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? id : title
    }

    /// The video's length as the list shows it: minutes and seconds, with
    /// hours when there are any.
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        let pattern: Duration.TimeFormatStyle.Pattern = whole >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(whole).formatted(.time(pattern: pattern))
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

enum BundleError: LocalizedError {
    case unsupportedVersion(Int)
    case badStatus(Int)
    case notABundle

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "The bundle is version \(version); this app reads version \(VideoBundle.supportedVersion)."
        case .badStatus(let code):
            "The host answered HTTP \(code)."
        case .notABundle:
            "The host did not give a bundle."
        }
    }
}
