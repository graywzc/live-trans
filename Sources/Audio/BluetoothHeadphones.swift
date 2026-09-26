import Foundation
import IOBluetooth

/// Paired Bluetooth headphones. Core Audio lists a pair only once its audio
/// link to the Mac is up, and hides it again behind a Multi-Output Device
/// that plays through it; System Settings shows every paired pair and brings
/// the link up when one is chosen. So does the output picker, through here.
enum BluetoothHeadphones {
    /// The Core Audio UID a pair has once connected: its address with dashes,
    /// as a Multi-Output Device lists it among its sub-devices.
    static func outputUID(address: String) -> String {
        "\(address.uppercased().replacingOccurrences(of: ":", with: "-")):output"
    }

    /// Every paired pair of headphones or headset, as an output device, named
    /// as System Settings names it. Read from the system profiler rather than
    /// IOBluetooth, whose names are the pairs' own ("AirPods 4 (ANC)") rather
    /// than the ones given to them ("AirPods4-2"), and which asks for
    /// Bluetooth access just to list them.
    static func paired() async -> [SoundOutput.Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(profile: data)
    }

    /// The headphones in the profiler's report, connected pairs first.
    static func parse(profile: Data) -> [SoundOutput.Device] {
        guard let json = try? JSONSerialization.jsonObject(with: profile) as? [String: Any],
              let report = (json["SPBluetoothDataType"] as? [[String: Any]])?.first
        else { return [] }
        var found: [SoundOutput.Device] = []
        for key in ["device_connected", "device_not_connected"] {
            for entry in report[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let value = value as? [String: Any],
                          let type = value["device_minorType"] as? String,
                          ["Headphones", "Headset"].contains(type),
                          let address = value["device_address"] as? String
                    else { continue }
                    found.append(SoundOutput.Device(id: outputUID(address: address), name: name))
                }
            }
        }
        return found
    }

    /// Brings the pair's connection up, which asks for Bluetooth access the
    /// first time; Core Audio then adds the device, which SoundOutput waits
    /// for.
    @MainActor
    static func connect(outputUID: String) -> Bool {
        let address = outputUID.replacingOccurrences(of: ":output", with: "")
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        if device.isConnected() { return true }
        return device.openConnection() == kIOReturnSuccess
    }
}
