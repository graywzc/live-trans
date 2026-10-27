import Foundation

/// UserDefaults keys. The ones here are kept by both apps, under the same
/// names, and read by the code they share; each app adds its own in an
/// extension, and registers the defaults for all of them.
enum AppSettings {
    static let showFurigana = "showFurigana"
    static let captionFontSize = "captionFontSize"
    static let analysisURL = "analysisURL"
    static let analysisModel = "analysisModel"

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
}
