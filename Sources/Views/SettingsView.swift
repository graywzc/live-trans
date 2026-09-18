import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.sshHost) private var sshHost = ""
    @AppStorage(AppSettings.asrPort) private var asrPort = 8770
    @AppStorage(AppSettings.remoteDir) private var remoteDir = ""
    @AppStorage(AppSettings.remotePython) private var remotePython = ""
    @AppStorage(AppSettings.inputDeviceName) private var inputDeviceName = ""
    @AppStorage(AppSettings.autoRouteOutput) private var autoRouteOutput = true
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 22.0
    @AppStorage(AppSettings.sensitivity) private var sensitivity = 0.5
    @AppStorage(AppSettings.keepOnTop) private var keepOnTop = false

    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: $inputDeviceName) {
                    Text("System default").tag("")
                    // A saved device that is unplugged right now stays
                    // selectable rather than silently changing the setting.
                    if !inputDeviceName.isEmpty, !devices.contains(where: { $0.name == inputDeviceName }) {
                        Text("\(inputDeviceName) (not connected)").tag(inputDeviceName)
                    }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.name)
                    }
                }
                Toggle("Switch sound output while captioning", isOn: $autoRouteOutput)
                Slider(value: $sensitivity, in: 0...1) {
                    Text("Sensitivity")
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Choose BlackHole to caption what the Mac is playing. While captioning, sound "
                    + "output moves to the Multi-Output Device that contains BlackHole and your current "
                    + "speakers or headphones, and moves back when you stop. Raise sensitivity if quiet "
                    + "speech is missed; the orange mark on the level meter is the speech threshold.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("SSH host", text: $sshHost)
                TextField("Port", value: $asrPort, format: .number.grouping(.never))
                TextField("Remote directory", text: $remoteDir)
                TextField("Remote Python", text: $remotePython)
            } header: {
                Text("GPU server")
            } footer: {
                Text("The server is started over ssh when captioning starts and shut down when it "
                    + "stops. Changes apply the next time you press Start.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Captions") {
                Toggle("Furigana", isOn: $showFurigana)
                Slider(value: $fontSize, in: 14...48, step: 1) {
                    Text("Text size")
                }
                Toggle("Keep window on top", isOn: $keepOnTop)
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            devices = AudioInputDevice.all()
        }
    }
}
