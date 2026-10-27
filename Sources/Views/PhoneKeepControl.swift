import SwiftUI

/// The Dev tab's control for the video kept for the phone: what the host
/// holds of it, the way to ask for it, and once it is there, to let it go.
/// Dev mode only, like the cache it goes in: nothing is kept in production.
struct PhoneKeepControl: View {
    /// The host's word: "none", "running", "done" or "failed: <why>".
    let bundle: String
    /// Seconds of the video fetched so far, and how long it is.
    let fetched: Double
    let duration: Double?
    /// Whether a keep can be asked for: a job whose captions have reached
    /// the end, with no fetch of the video running.
    let canKeep: Bool
    let onKeep: () -> Void
    let onForget: () -> Void

    var body: some View {
        if bundle == "done" {
            Menu {
                Button("Forget the iPhone's copy", action: onForget)
            } label: {
                // A menu's label does not take the row's font.
                Label(Self.title(bundle: bundle, fetched: fetched, duration: duration), systemImage: "iphone")
                    .font(.caption)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help(Self.help(bundle: bundle, canKeep: canKeep))
        } else {
            Button(action: onKeep) {
                Label(Self.title(bundle: bundle, fetched: fetched, duration: duration), systemImage: "iphone")
            }
            .disabled(!canKeep || bundle == "running")
            .help(Self.help(bundle: bundle, canKeep: canKeep))
        }
    }

    /// What the control reads: the ask, the fetch's progress, or that the
    /// video is there.
    static func title(bundle: String, fetched: Double, duration: Double?) -> String {
        switch bundle {
        case "done":
            return "On the host for the iPhone"
        case "running":
            guard let duration, duration > 0 else { return "Keeping for iPhone…" }
            let percent = min(max(Int((fetched / duration * 100).rounded()), 0), 99)
            return "Keeping for iPhone · \(percent)%"
        default:
            return "Keep for iPhone"
        }
    }

    /// Its tooltip: what pressing does, or why it cannot be pressed yet.
    static func help(bundle: String, canKeep: Bool) -> String {
        if bundle == "done" {
            return "The video is on the host with its captions, for the iPhone app to download"
        }
        if bundle == "running" {
            return "The host is fetching the video for the iPhone"
        }
        let ask = canKeep
            ? "Have the host keep this video with its captions, for the iPhone app to download"
            : "Once the step's captions have reached the end, the host can keep the video with them for the iPhone"
        if bundle.hasPrefix("failed") {
            return "Keeping the video \(bundle). \(ask)"
        }
        return ask
    }
}
