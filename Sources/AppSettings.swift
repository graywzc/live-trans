import Foundation

/// UserDefaults keys, shared by the views (@AppStorage) and the engine.
///
/// Any of them can be overridden for one run from the command line, which is
/// how the app is pointed at a scratch server:
///
///     LiveTrans.app/Contents/MacOS/LiveTrans -asrPort 8771 -remoteDir '~/scratch'
enum AppSettings {
    static let sshHost = "sshHost"
    static let asrPort = "asrPort"
    static let remoteDir = "remoteDir"
    static let remotePython = "remotePython"
    static let idleTimeout = "idleTimeout"
    static let inputDeviceName = "inputDeviceName"
    static let autoRouteOutput = "autoRouteOutput"
    static let showFurigana = "showFurigana"
    static let captionFontSize = "captionFontSize"
    static let sensitivity = "sensitivity"
    static let keepOnTop = "keepOnTop"
    static let demoAudioPath = "demoAudioPath"
    static let autoStart = "autoStart"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sshHost: "",
            asrPort: 8770,
            remoteDir: "~/livetrans",
            remotePython: "~/venvs/livetrans/bin/python",
            idleTimeout: 180,
            inputDeviceName: "BlackHole",
            autoRouteOutput: true,
            showFurigana: true,
            captionFontSize: 22.0,
            sensitivity: 0.5,
            keepOnTop: false,
        ])
    }

    static var serverConfig: ServerConfig {
        let defaults = UserDefaults.standard
        return ServerConfig(
            sshHost: defaults.string(forKey: sshHost) ?? "",
            port: defaults.integer(forKey: asrPort),
            remoteDir: defaults.string(forKey: remoteDir) ?? "",
            remotePython: defaults.string(forKey: remotePython) ?? "",
            idleTimeout: defaults.integer(forKey: idleTimeout)
        )
    }

    /// The 0...1 sensitivity slider as the VAD's speech-to-noise ratio: from 6x
    /// the noise floor (only clear, loud speech) down to 1.8x (quiet speech,
    /// at the cost of more false starts on a noisy microphone).
    static var speechRatio: Float {
        let value = Float(UserDefaults.standard.double(forKey: sensitivity))
        return 6.0 - 4.2 * min(max(value, 0), 1)
    }
}
