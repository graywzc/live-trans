import Foundation

/// The phone's own keys, after the shared ones in `Shared/Settings.swift`.
extension AppSettings {
    /// The folder the host serves the bundles from: `index.json` and a
    /// folder per bundle under it.
    static let bundleHost = "bundleHost"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            bundleHost: "",
            showFurigana: true,
            captionFontSize: 20.0,
            analysisURL: "",
            analysisModel: "",
        ])
    }

    /// The host as typed in Settings, as a URL: nil until there is one that
    /// could be reached.
    static func hostURL(_ text: String) -> URL? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), let scheme = url.scheme else { return nil }
        switch scheme {
        case "http", "https": return url.host() == nil ? nil : url
        case "file": return url
        default: return nil
        }
    }
}
