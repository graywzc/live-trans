import Foundation

/// UserDefaults keys, shared by the views (@AppStorage) and the engine.
///
/// Any of them can be overridden for one run from the command line, which is
/// how the app is pointed at a scratch server:
///
///     LiveTrans.app/Contents/MacOS/LiveTrans -asrPort 8771 -remoteDir '~/scratch'
/// The running build, as shown in the window: "v0.1.2" for a release. Local
/// builds all carry project.yml's placeholder version, so they are marked
/// rather than passing for whichever release that number once was.
enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return format(version: version, isDebug: isDebug)
    }

    static func format(version: String?, isDebug: Bool) -> String {
        let base = version.map { "v\($0)" } ?? "v?"
        return isDebug ? "\(base) dev" : base
    }

    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

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
    /// The panel was Jisho's alone when the key was named.
    static let sidePanelWidth = "jishoPanelWidth"
    static let analysisURL = "analysisURL"
    static let analysisModel = "analysisModel"
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
            sidePanelWidth: 440.0,
            analysisURL: "",
            analysisModel: "",
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

    /// Nil until an LLM server has been entered in Settings.
    static var analysisClient: AnalysisClient? {
        let defaults = UserDefaults.standard
        let address = (defaults.string(forKey: analysisURL) ?? "").trimmingCharacters(in: .whitespaces)
        let model = (defaults.string(forKey: analysisModel) ?? "").trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, let url = URL(string: address), url.scheme?.hasPrefix("http") == true,
              url.host != nil
        else { return nil }
        return AnalysisClient(baseURL: url, model: model)
    }

    /// The 0...1 sensitivity slider as the VAD's speech-to-noise ratio: from 6x
    /// the noise floor (only clear, loud speech) down to 1.8x (quiet speech,
    /// at the cost of more false starts on a noisy microphone).
    static var speechRatio: Float {
        let value = Float(UserDefaults.standard.double(forKey: sensitivity))
        return 6.0 - 4.2 * min(max(value, 0), 1)
    }
}
