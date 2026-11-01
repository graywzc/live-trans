import SwiftUI

struct MobileSettingsView: View {
    @AppStorage(AppSettings.bundleHost) private var bundleHost = ""
    @AppStorage(AppSettings.analysisURL) private var analysisURL = ""
    @AppStorage(AppSettings.analysisModel) private var analysisModel = ""
    @AppStorage(AppSettings.showFurigana) private var showFurigana = true
    @AppStorage(AppSettings.captionFontSize) private var fontSize = 20.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    addressField("Host", text: $bundleHost)
                } header: {
                    Text("Bundles")
                } footer: {
                    Text("The folder the GPU host serves its dev cache from, over your tailnet: the bundles "
                        + "kept for the iPhone from the Mac's Dev tab are listed from it.")
                }

                Section {
                    addressField("Server URL", text: $analysisURL)
                    TextField("Model", text: $analysisModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Sentence analysis")
                } footer: {
                    Text("An OpenAI-compatible chat endpoint, as on the Mac: the base URL ending in /v1, and "
                        + "the model's name.")
                }

                Section {
                    Toggle("Furigana", isOn: $showFurigana)
                    VStack(alignment: .leading) {
                        Slider(value: $fontSize, in: 14...32, step: 1) {
                            Text("Text size")
                        }
                        Text("今日はいい天気ですね。")
                            .font(.system(size: fontSize))
                    }
                } header: {
                    Text("Captions")
                } footer: {
                    Text("Readings over the kanji come from the system's Japanese tokenizer, offline.")
                }

                Section {
                    LabeledContent("Version", value: AppVersion.current)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func addressField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

/// What this build is: the commit it was made from, as `git describe`
/// wrote it into the app at build time (last tag, commits since, the
/// commit's hash). The refresh that installs the app sets no marketing
/// version, so that alone would always read the same.
enum AppVersion {
    static let buildFile = "build.txt"

    static var current: String {
        let build = Bundle.main.url(forResource: buildFile, withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return text(build: build, marketing: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    static func text(build: String?, marketing: String?) -> String {
        if let build = build?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty { return build }
        return marketing ?? "unknown"
    }
}
