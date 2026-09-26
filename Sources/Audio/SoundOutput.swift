import CoreAudio
import Foundation
import Observation

/// The Mac's sound output as what you are listening on: the speakers, a pair
/// of AirPods, the dock. Choosing one here is choosing it in System Settings,
/// and the router then puts BlackHole alongside it while captioning.
///
/// So the listening device is read through any Multi-Output Device: on
/// "BlackHole+Plugable" you are listening on the Plugable, and that is what
/// the picker says.
@MainActor
@Observable
final class SoundOutput {
    typealias Aggregate = AudioHardware.Aggregate

    struct Device: Identifiable, Equatable {
        /// The Core Audio device UID.
        let id: String
        let name: String
    }

    /// The device list as of one moment, so the choices can be worked out
    /// without Core Audio.
    struct Snapshot: Equatable {
        /// Every device that can play something, other than Multi-Output Devices.
        var devices: [Device] = []
        var aggregates: [Aggregate] = []
        /// The default output's UID.
        var current: String?
        /// The capture device (BlackHole), which is nothing to listen on.
        var capture: String?
        var captureName = "BlackHole"
        /// Paired Bluetooth headphones, whether or not Core Audio has them.
        /// A connected pair is in `devices` too, under Core Audio's name.
        var headphones: [Device] = []

        /// What to offer: the devices you can hear, then the headphones
        /// that would have to be connected first.
        var choices: [Device] {
            devices.filter { $0.id != capture } + headphones.filter(needsConnecting)
        }

        /// A pair of headphones Core Audio does not have yet.
        func needsConnecting(_ device: Device) -> Bool {
            !devices.contains { $0.id == device.id }
        }

        /// What is being listened on: the output itself, or through a
        /// Multi-Output Device that carries the captions, the device beside
        /// the capture device in it. Any other aggregate is left as itself:
        /// the router would not know what to do with it either.
        var listening: Device? {
            guard let current else { return nil }
            if let device = devices.first(where: { $0.id == current }) { return device }
            guard let capture, let aggregate = aggregates.first(where: { $0.uid == current }),
                  aggregate.subDeviceUIDs.contains(capture)
            else { return nil }
            return choices.first { aggregate.subDeviceUIDs.contains($0.id) }
        }

        /// The Multi-Output Device that plays on `device` and feeds the capture
        /// device too: what the router switches to while captioning. Nil when
        /// none is set up, in which case captioning on that device would leave
        /// the captions silent.
        func feed(for device: Device) -> Aggregate? {
            guard let capture else { return nil }
            return aggregates.first {
                $0.subDeviceUIDs.contains(capture) && $0.subDeviceUIDs.contains(device.id)
            }
        }

        /// What the picker says: the listening device, or whatever odd thing
        /// the output is set to.
        var label: String {
            if let listening { return listening.name }
            guard let current else { return "No output" }
            return aggregates.first { $0.uid == current }?.name ?? current
        }
    }

    private(set) var snapshot: Snapshot
    /// Headphones being connected, to become the output once Core Audio
    /// has them.
    private(set) var connecting: Device?
    /// Looks for them until they appear or the wait is up.
    private var connectingWatch: Task<Void, Never>?
    /// Why the last choice did not take, to be shown and cleared.
    var problem: String?
    private let isLive: Bool

    /// What the picker says, including a pair on its way.
    var label: String {
        if let connecting { return "Connecting \(connecting.name)…" }
        return snapshot.label
    }
    /// Removed in deinit, which runs off the main actor.
    private nonisolated(unsafe) var listener: AudioObjectPropertyListenerBlock?

    /// Follows the Mac's devices and default output.
    init() {
        isLive = true
        snapshot = Snapshot()
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioHardware.system, &AudioHardware.defaultOutputAddress, .main, listener
        )
        AudioObjectAddPropertyListenerBlock(AudioHardware.system, &AudioHardware.devicesAddress, .main, listener)
    }

    /// A fixed device list, for tests: choosing only moves `current`.
    init(snapshot: Snapshot) {
        isLive = false
        self.snapshot = snapshot
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(
                AudioHardware.system, &AudioHardware.defaultOutputAddress, .main, listener
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioHardware.system, &AudioHardware.devicesAddress, .main, listener
            )
        }
    }

    /// Makes `device` the Mac's sound output. While captioning, the router
    /// hears the change and moves on to the Multi-Output Device that pairs
    /// it with BlackHole. Headphones Core Audio lacks are connected first
    /// and become the output when it lists them.
    func choose(_ device: Device) {
        connectingWatch?.cancel()
        connecting = nil
        guard isLive else {
            if snapshot.needsConnecting(device) {
                connecting = device
            } else {
                snapshot.current = device.id
            }
            return
        }
        if snapshot.needsConnecting(device) {
            guard BluetoothHeadphones.connect(outputUID: device.id) else {
                print("output: could not connect \(device.name)")
                problem = "Couldn't connect \(device.name). Open their case or put them in, then try again."
                return
            }
            print("output: connecting \(device.name)")
            connecting = device
            // Core Audio does not announce a hidden device, so look for it.
            connectingWatch = Task { [weak self] in
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, self.connecting?.id == device.id else { return }
                    self.refresh()
                }
                guard !Task.isCancelled, let self, self.connecting?.id == device.id else { return }
                print("output: \(device.name) did not appear")
                self.connecting = nil
                self.problem = "\(device.name) connected but never became a sound output. Try choosing them again."

            }
            return
        }
        guard AudioHardware.setDefaultOutput(uid: device.id) else { return }
        print("output: chosen \(device.name)")
        refresh()
    }

    /// Adds the paired Bluetooth headphones to the list, when it is opened:
    /// reading them runs the system profiler, which takes a moment.
    func refreshHeadphones() {
        guard isLive else { return }
        Task { [weak self] in
            let headphones = await BluetoothHeadphones.paired()
            guard let self, headphones != self.snapshot.headphones else { return }
            self.snapshot.headphones = headphones
            self.refresh()
        }
    }

    func refresh() {
        guard isLive else { return }
        let capture = AudioInputDevice.matching(
            UserDefaults.standard.string(forKey: AppSettings.inputDeviceName) ?? ""
        )
        var devices: [Device] = []
        var aggregates: [Aggregate] = []
        for id in AudioHardware.deviceIDs() {
            guard let uid = AudioHardware.uid(of: id) else { continue }
            let name = AudioHardware.name(of: id) ?? uid
            if let subDevices = AudioHardware.subDeviceUIDs(of: id) {
                aggregates.append(Aggregate(uid: uid, subDeviceUIDs: subDevices, name: name))
            } else if AudioHardware.hasOutput(id) {
                devices.append(Device(id: uid, name: name))
            }
        }
        // Connected headphones are hidden from the list while a Multi-Output
        // Device plays through them, but are there to be asked for.
        for pair in snapshot.headphones where !devices.contains(where: { $0.id == pair.id }) {
            guard let id = AudioHardware.deviceID(uid: pair.id) else { continue }
            devices.append(Device(id: pair.id, name: AudioHardware.name(of: id) ?? pair.name))
        }
        let fresh = Snapshot(
            devices: devices, aggregates: aggregates, current: AudioHardware.defaultOutputUID(),
            capture: capture?.id, captureName: capture?.name ?? "BlackHole", headphones: snapshot.headphones
        )
        if fresh != snapshot { snapshot = fresh }
        if let connecting, devices.contains(where: { $0.id == connecting.id }) {
            connectingWatch?.cancel()
            self.connecting = nil
            choose(connecting)
        }
    }
}
