import XCTest
@testable import LiveTrans

/// Reading the WAV file the host gives a stretch of audio as.
final class ClipPlayerTests: XCTestCase {
    /// A WAV file of `samples`, as Python's wave module writes one.
    private func wav(_ samples: [Int16], rate: UInt32 = 16000, channels: UInt16 = 1, bits: UInt16 = 16) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let body = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + body))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(channels)
        put(rate)
        put(rate * UInt32(channels) * UInt32(bits / 8))
        put(channels * bits / 8)
        put(bits)
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(body))
        for sample in samples { put(sample) }
        return data
    }

    func testSamplesComeBackAsFloats() throws {
        let clip = try WAVClip(data: wav([0, 16384, -32768, 32767]))
        XCTAssertEqual(clip.sampleRate, 16000)
        XCTAssertEqual(clip.samples, [0, 0.5, -1, 32767 / 32768])
        XCTAssertEqual(clip.seconds, 4 / 16000, accuracy: 1e-9)
    }

    func testAnEmptyClipIsFine() throws {
        XCTAssertEqual(try WAVClip(data: wav([])).samples, [])
    }

    func testWhatIsNotAWAVFileIsRefused() {
        XCTAssertThrowsError(try WAVClip(data: Data("hello".utf8)))
        XCTAssertThrowsError(try WAVClip(data: wav([1, 2], channels: 2)), "two channels")
        XCTAssertThrowsError(try WAVClip(data: Data(wav([1, 2]).prefix(30))), "cut short")
    }
}
