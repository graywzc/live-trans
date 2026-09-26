import CoreAudio
import Foundation

/// Core Audio's device list, for the output router and the output picker.
///
/// Devices are handled by UID, which is stable across reboots and replugging;
/// names are only for showing.
enum AudioHardware {
    /// A Multi-Output (or aggregate) device and the devices it feeds.
    struct Aggregate: Equatable {
        var uid: String
        var subDeviceUIDs: [String]
        var name = ""
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func deviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func aggregates() -> [Aggregate] {
        deviceIDs().compactMap { id in
            guard let uid = uid(of: id), let subDevices = subDeviceUIDs(of: id) else { return nil }
            return Aggregate(uid: uid, subDeviceUIDs: subDevices, name: name(of: id) ?? uid)
        }
    }

    /// Nil for anything but an aggregate device: only those have the property.
    static func subDeviceUIDs(of id: AudioDeviceID) -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list) == noErr else { return nil }
        return list?.takeRetainedValue() as? [String]
    }

    /// Whether the device can play anything. A USB dock lists a second
    /// "Plugable Audio" with no output streams at all.
    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &defaultOutputAddress, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return uid(of: id)
    }

    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard var id = deviceID(uid: uid) else { return false }
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(system, &defaultOutputAddress, 0, nil, size, &id) == noErr
    }

    static func name(uid: String) -> String? {
        deviceID(uid: uid).flatMap(name(of:))
    }

    /// The device with this UID, whether or not it is in the device list:
    /// Bluetooth headphones are hidden from it while a Multi-Output Device
    /// plays through them. Nil for a device that is not there at all, such
    /// as headphones not connected.
    static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func uid(of id: AudioObjectID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    static func name(of id: AudioObjectID) -> String? {
        string(id, kAudioObjectPropertyName)
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
