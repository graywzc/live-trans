import AVFoundation

struct AudioInputDevice: Identifiable, Equatable {
    /// The Core Audio device UID, stable across reboots and replugging.
    let id: String
    let name: String

    static func all() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// First device whose name contains `name`, case-insensitively, so
    /// "BlackHole" finds "BlackHole 2ch".
    static func matching(_ name: String) -> AudioInputDevice? {
        guard !name.isEmpty else { return nil }
        return all().first { $0.name.localizedCaseInsensitiveContains(name) }
    }
}

/// Captures from an audio input device: BlackHole for whatever the Mac is
/// playing, or a microphone.
///
/// This is an AVCaptureSession rather than an AVAudioEngine. The engine builds
/// its input node around the system default input and copes badly with being
/// pointed elsewhere: when the default is, say, AirPods at 24 kHz and the
/// capture device is BlackHole at 48 kHz, it raises an Objective-C exception
/// over the mismatch. A capture session opens the device asked for, whatever
/// the default is, and converts to the wire format itself.
final class InputDeviceSource: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum CaptureError: LocalizedError {
        case noInput
        case cannotOpen(String)

        var errorDescription: String? {
            switch self {
            case .noInput: "No audio input device is available."
            case .cannotOpen(let name): "Could not open the audio input \"\(name)\"."
            }
        }
    }

    /// nil captures from the system default input.
    private let device: AudioInputDevice?
    private let queue = DispatchQueue(label: "com.larrywang.livetrans.capture")
    private var session: AVCaptureSession?
    private var continuation: AsyncStream<Data>.Continuation?
    private var observers: [NSObjectProtocol] = []
    /// Touched only on `queue`.
    private var chunker = FrameChunker()

    init(device: AudioInputDevice?) {
        self.device = device
    }

    func start() throws -> AsyncStream<Data> {
        let captureDevice = device.flatMap { AVCaptureDevice(uniqueID: $0.id) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let captureDevice else { throw CaptureError.noInput }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        let output = AVCaptureAudioDataOutput()
        // Ask for the server's wire format directly: PCM s16le mono 16 kHz.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureError.cannotOpen(captureDevice.localizedName)
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.continuation = continuation
        self.session = session

        // Ending the stream tells the caption engine the input is gone, which
        // it reports; silently captioning nothing would be worse.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                self?.stop()
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: captureDevice, queue: .main) { [weak self] _ in
                self?.stop()
            },
        ]

        // startRunning blocks while the device opens; keep that off the main thread.
        queue.async { session.startRunning() }
        return stream
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let session {
            queue.async { session.stopRunning() }
        }
        session = nil
        continuation?.finish()
        continuation = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var pcm = Data(count: length)
        let status = pcm.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        for frame in chunker.push(pcm) {
            continuation?.yield(frame)
        }
    }
}
