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
    struct Aggregate: Equatable {
        var uid: String
        var subDeviceUIDs: [String]
    }

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

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func engage(captureUID: String) {
        self.captureUID = captureUID
        reroute()

        // Putting AirPods in mid-session makes macOS switch the output to them
        // alone, which would silently cut the captions off; follow it.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reroute()
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(Self.system, &Self.defaultOutputAddress, .main, listener)
    }

    func restore() {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(Self.system, &Self.defaultOutputAddress, .main, listener)
        }
        listener = nil
        captureUID = nil
        // Only undo our own change: if the output was moved elsewhere since,
        // that was deliberate and not ours to revert.
        if let original, let routed, Self.defaultOutputUID() == routed {
            Self.setDefaultOutput(uid: original)
            print("output: restored to \(Self.name(uid: original) ?? original)")
        }
        original = nil
        routed = nil
    }

    private func reroute() {
        guard let captureUID, let output = Self.defaultOutputUID(),
              let target = Self.route(output: output, capture: captureUID, aggregates: Self.aggregates())
        else { return }
        guard Self.setDefaultOutput(uid: target) else { return }
        original = output
        routed = target
        print("output: \(Self.name(uid: output) ?? output) -> \(Self.name(uid: target) ?? target)")
    }

    // MARK: - Core Audio

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func aggregates() -> [Aggregate] {
        devices().compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var list: Unmanaged<CFArray>?
            var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            // Only aggregate devices have this property.
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list) == noErr,
                  let subDevices = list?.takeRetainedValue() as? [String]
            else { return nil }
            return Aggregate(uid: uid, subDeviceUIDs: subDevices)
        }
    }

    private static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &defaultOutputAddress, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    @discardableResult
    private static func setDefaultOutput(uid: String) -> Bool {
        guard var id = devices().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }) else {
            return false
        }
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(system, &defaultOutputAddress, 0, nil, size, &id) == noErr
    }

    private static func name(uid: String) -> String? {
        devices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
            .flatMap { string($0, kAudioObjectPropertyName) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
