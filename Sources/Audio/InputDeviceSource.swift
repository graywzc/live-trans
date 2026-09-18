import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String

    /// Every device with at least one input channel.
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(of: id) > 0, let name = name(of: id) else { return nil }
            return AudioInputDevice(id: id, name: name)
        }
    }

    /// First device whose name contains `name`, case-insensitively, so
    /// "BlackHole" finds "BlackHole 2ch".
    static func matching(_ name: String) -> AudioInputDevice? {
        guard !name.isEmpty else { return nil }
        return all().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Captures from a Core Audio input device: BlackHole for whatever the Mac is
/// playing, or a microphone.
final class InputDeviceSource: AudioSource {
    enum CaptureError: LocalizedError {
        case noInput

        var errorDescription: String? {
            "The audio input device has no usable input."
        }
    }

    /// nil captures from the system default input.
    private let device: AudioInputDevice?
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?
    private var configObserver: NSObjectProtocol?

    init(device: AudioInputDevice?) {
        self.device = device
    }

    func start() throws -> AsyncStream<Data> {
        if let device {
            try engine.inputNode.auAudioUnit.setDeviceID(device.id)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.continuation = continuation
        try startEngine()

        // A sample-rate or device change stops the engine and invalidates the
        // tap's format; rebuild both.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.continuation != nil else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.startEngine()
        }
        return stream
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInput
        }
        let framer = try PCMFramer(inputFormat: format)
        let continuation = self.continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            for frame in framer.push(buffer) {
                continuation?.yield(frame)
            }
        }
        engine.prepare()
        try engine.start()
    }
}
