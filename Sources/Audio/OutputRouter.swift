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

    private var captureUID: String?
    /// What the output was before we changed it, and what we changed it to.
    private var original: String?
    private var routed: String?
    private var listener: AudioObjectPropertyListenerBlock?

    func engage(captureUID: String) {
        self.captureUID = captureUID
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
    }

    private func reroute() {
        guard let captureUID, let output = AudioHardware.defaultOutputUID(),
              let target = Self.route(output: output, capture: captureUID, aggregates: AudioHardware.aggregates())
        else { return }
        guard AudioHardware.setDefaultOutput(uid: target) else { return }
        original = output
        routed = target
        print("output: \(AudioHardware.name(uid: output) ?? output) -> \(AudioHardware.name(uid: target) ?? target)")
    }
}
