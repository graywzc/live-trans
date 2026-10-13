import AVFoundation
import Observation

/// A WAV file read into samples: 16-bit PCM, one channel, as the GPU host
/// gives a stretch of a video's audio.
struct WAVClip: Equatable {
    enum ReadError: Error {
        case notWAV
        case unsupported(String)
    }

    let sampleRate: Double
    let samples: [Float]

    var seconds: Double { Double(samples.count) / sampleRate }

    init(data: Data) throws {
        guard data.count >= 12, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw ReadError.notWAV
        }
        func word(_ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + at + $1]) << (8 * UInt32($1)) }
        }
        func half(_ at: Int) -> UInt16 { UInt16(word(at) & 0xffff) }
        var at = 12
        var format: (channels: Int, rate: Double, bits: Int)?
        var pcm: Data?
        while at + 8 <= data.count {
            let id = String(decoding: data[data.startIndex + at..<data.startIndex + at + 4], as: UTF8.self)
            let size = Int(word(at + 4))
            let body = at + 8
            guard body + size <= data.count else { break }
            switch id {
            case "fmt " where size >= 16:
                format = (Int(half(body + 2)), Double(word(body + 4)), Int(half(body + 14)))
                if half(body) != 1 { throw ReadError.unsupported("not PCM") }
            case "data":
                pcm = data.subdata(in: data.startIndex + body..<data.startIndex + body + size)
            default:
                break
            }
            at = body + size + size % 2
        }
        guard let format, let pcm else { throw ReadError.notWAV }
        guard format.channels == 1, format.bits == 16 else {
            throw ReadError.unsupported("\(format.channels) channels, \(format.bits) bits")
        }
        sampleRate = format.rate
        samples = pcm.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }
}

/// Plays a clip on one output device: the one being listened on, rather
/// than the Mac's default output, which while captioning is the
/// Multi-Output Device that feeds BlackHole too, so the live listener
/// would hear the clip and caption it.
@MainActor
@Observable
final class ClipPlayer {
    private(set) var isPlaying = false
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    /// Plays `clip` on the device with `deviceUID`, or the default output
    /// when nil or not found, in place of whatever was playing.
    func play(_ clip: WAVClip, on deviceUID: String?) throws {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(clip.samples.count, 1)))
        else { return }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress, let channel = buffer.floatChannelData?[0] else { return }
            channel.update(from: base, count: samples.count)
        }
        let engine = AVAudioEngine()
        if let deviceUID, let id = AudioHardware.deviceID(uid: deviceUID), let unit = engine.outputNode.audioUnit {
            var device = id
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(engine) }
        }
        node.play()
        self.engine = engine
        self.node = node
        isPlaying = true
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        isPlaying = false
    }

    private func finished(_ engine: AVAudioEngine) {
        guard engine === self.engine else { return }
        stop()
    }

    /// The device being listened on: the default output, or, through a
    /// Multi-Output Device carrying the capture device, the device beside
    /// it. Nil when there is no telling.
    static func listeningDeviceUID() -> String? {
        guard let current = AudioHardware.defaultOutputUID(), let id = AudioHardware.deviceID(uid: current) else {
            return nil
        }
        guard let subDevices = AudioHardware.subDeviceUIDs(of: id) else { return current }
        let capture = AudioInputDevice.matching(UserDefaults.standard.string(forKey: AppSettings.inputDeviceName) ?? "")?.id
        return subDevices.first { $0 != capture } ?? current
    }
}
