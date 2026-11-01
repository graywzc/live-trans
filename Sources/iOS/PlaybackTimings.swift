import AVFoundation
import UIKit

/// How the player is keeping up on this phone, for reading on the GPU
/// host wherever the phone is: how late the highlight moved, how long a
/// tap took to play, frames the screen missed, and where the sound goes.
/// Numbers only, nothing of what is being watched.
struct PlaybackTimings {
    /// One period's numbers, as the host's phone_service.py takes them.
    struct Report: Encodable, Equatable {
        var build = AppVersion.current
        var seconds = 0.0
        var frames = 0
        var hitches = 0
        var worstFrameMs = 0.0
        var highlights = 0
        var highlightLateMedianMs = 0.0
        var highlightLateMaxMs = 0.0
        var taps = 0
        var tapMedianMs = 0.0
        var tapMaxMs = 0.0
        var route = ""
        var audioLatencyMs = 0.0
        var lowPower = false
        var thermal = ""
    }

    /// A frame this long is one the eye can see was missed.
    static let hitch = 50.0
    static let port = 8773

    private var frames: [Double] = []
    private var highlights: [Double] = []
    private var taps: [Double] = []

    var isEmpty: Bool { frames.isEmpty && highlights.isEmpty && taps.isEmpty }

    mutating func frame(ms: Double) {
        frames.append(ms)
    }

    /// How far past its start the video was when the sentence was lit.
    mutating func highlight(lateMs: Double) {
        highlights.append(max(lateMs, 0))
    }

    /// From the tap until the video was going at the sentence.
    mutating func tap(ms: Double) {
        taps.append(ms)
    }

    /// The period's numbers, starting the next.
    mutating func report(seconds: Double) -> Report {
        var report = Report()
        report.seconds = seconds
        report.frames = frames.count
        report.hitches = frames.filter { $0 > Self.hitch }.count
        report.worstFrameMs = frames.max() ?? 0
        report.highlights = highlights.count
        report.highlightLateMedianMs = Self.median(highlights)
        report.highlightLateMaxMs = highlights.max() ?? 0
        report.taps = taps.count
        report.tapMedianMs = Self.median(taps)
        report.tapMaxMs = taps.max() ?? 0
        self = PlaybackTimings()
        return report
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// The host's receiver: the machine the bundles come from, which the
    /// phone reaches over the tailnet at the gym as at home.
    static func endpoint(host: URL?) -> URL? {
        guard let host, let name = host.host(), let scheme = host.scheme, scheme != "file" else { return nil }
        return URL(string: "http://\(name):\(port)/timings")
    }
}

extension PlaybackTimings.Report {
    /// What only the system knows, at the moment of sending.
    @MainActor
    mutating func addConditions() {
        let audio = AVAudioSession.sharedInstance()
        route = audio.currentRoute.outputs.first?.portType.rawValue ?? ""
        audioLatencyMs = audio.outputLatency * 1000
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// A report that does not get there is simply lost.
    func send(to url: URL) async {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let body = try? encoder.encode(self) else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        _ = try? await URLSession(configuration: .ephemeral).data(for: request)
    }
}

/// Calls back with the time between screen refreshes, paused or playing,
/// so a freeze on coming back to the app counts; not the time spent away.
final class FrameWatch: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private let onFrame: (Double) -> Void

    init(onFrame: @escaping (Double) -> Void) {
        self.onFrame = onFrame
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        NotificationCenter.default.addObserver(
            self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func wentAway() {
        last = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last { onFrame((link.timestamp - last) * 1000) }
        last = link.timestamp
    }
}
