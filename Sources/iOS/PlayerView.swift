import SwiftUI

/// Where the video plays with its captions. For now, what the bundle holds.
struct PlayerView: View {
    let bundle: VideoBundle

    var body: some View {
        VStack(spacing: 12) {
            Text(bundle.name)
                .font(.title2)
                .multilineTextAlignment(.center)
            Text("\(bundle.lines.count) lines · \(BundleNaming.length(bundle.duration))")
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(bundle.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
