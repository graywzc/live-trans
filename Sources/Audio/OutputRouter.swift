import CoreAudio
import Foundation

/// While captioning, points the Mac's sound output at the Multi-Output Device
/// that feeds both the capture device (BlackHole) and whatever you are
/// listening on, then puts it back.
///
/// Nothing is matched by name. A Multi-Output Device lists its sub-devices, so
/// "the one containing BlackHole and the current output" finds BlackHole+AirPods
/// when the AirPods are in and BlackHole+Speakers when they are not. With no
/// such device set up, this does nothing.
final class OutputRouter {
    typealias Aggregate = AudioHardware.Aggregate

    /// The Multi-Output Device to switch to, or nil to leave the output alone:
    /// already routed, or nothing suitable exists.
    static func route(output: String, capture: String, aggregates: [Aggregate]) -> String? {
        if aggregates.contains(where: { $0.uid == output && $0.subDeviceUIDs.contains(capture) }) {
            return nil
        }
        return aggregates.first {
            $0.subDeviceUIDs.contains(capture) && $0.subDeviceUIDs.contains(output)
        }?.uid
    }

    /// How often the output may be taken off the device it was routed to
    /// within `fightWindow` before routing gives way. macOS can put the
    /// output back on AirPods the moment a Multi-Output Device starts
    /// playing through them; moved back each time, the output flipped twice
    /// a second, and Chrome, reopening its sound on every flip, played the
    /// video in stalls and jumps.
    static let fightCount = 3
    static let fightWindow: TimeInterval = 10

    /// Whether the output being taken away at `times` is a fight rather
    /// than a choice: `fightCount` of them within `fightWindow` of `now`.
    static func isFight(_ times: [Date], now: Date) -> Bool {
        times.filter { now.timeIntervalSince($0) <= fightWindow }.count >= fightCount
    }

    private var captureUID: String?
    /// What the output was before we changed it, and what we changed it to.
    private var original: String?
    private var routed: String?
    /// When the output was taken off `routed`; and whether routing has
    /// given way to whatever keeps taking it, for this session.
    private var takenAway: [Date] = []
    private var yielded = false
    private var listener: AudioObjectPropertyListenerBlock?

    func engage(captureUID: String) {
        self.captureUID = captureUID
        takenAway = []
        yielded = false
        reroute()

        // Putting AirPods in mid-session makes macOS switch the output to them
        // alone, which would silently cut the captions off; follow it. The
        // same brings the output picker's choice under BlackHole.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reroute()
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioHardware.system, &AudioHardware.defaultOutputAddress, .main, listener
        )
    }

    func restore() {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(
                AudioHardware.system, &AudioHardware.defaultOutputAddress, .main, listener
            )
        }
        listener = nil
        captureUID = nil
        // Only undo our own change: if the output was moved elsewhere since,
        // that was deliberate and not ours to revert.
        if let original, let routed, AudioHardware.defaultOutputUID() == routed {
            AudioHardware.setDefaultOutput(uid: original)
            print("output: restored to \(AudioHardware.name(uid: original) ?? original)")
        }
        original = nil
        routed = nil
        takenAway = []
        yielded = false
    }

    private func reroute() {
        guard let captureUID, !yielded, let output = AudioHardware.defaultOutputUID() else { return }
        if let routed, output != routed {
            let now = Date()
            takenAway.append(now)
            takenAway.removeAll { now.timeIntervalSince($0) > Self.fightWindow }
            if Self.isFight(takenAway, now: now) {
                yielded = true
                let name = AudioHardware.name(uid: output) ?? output
                print("output: taken back to \(name) \(takenAway.count) times in \(Int(Self.fightWindow)) s; left there")
                ActivityLog.tell(
                    "The Mac keeps moving the sound back to \(name), so LiveTrans stopped moving it to BlackHole: "
                        + "live captions won't hear what plays until captioning starts again"
                )
                return
            }
        }
        guard let target = Self.route(output: output, capture: captureUID, aggregates: AudioHardware.aggregates())
        else { return }
        guard AudioHardware.setDefaultOutput(uid: target) else { return }
        original = output
        routed = target
        print("output: \(AudioHardware.name(uid: output) ?? output) -> \(AudioHardware.name(uid: target) ?? target)")
    }
}
