import SwiftUI

/// The bundles on the host and on the phone: fetched, played, deleted.
struct LibraryView: View {
    @Environment(BundleStore.self) private var store
    @AppStorage(AppSettings.bundleHost) private var hostText = ""
    /// The video on screen. Kept with the scene, so when iOS closes the
    /// app in the background it comes back there; swiped away by hand,
    /// it starts at the list.
    @SceneStorage("openBundle") private var openID = ""
    @State private var path: [String] = []
    @State private var reopen = ReopenOnce()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(store.items) { item in
                        row(item)
                    }
                }
            }
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No bundles", systemImage: "film.stack",
                        description: Text(
                            hostText.isEmpty
                                ? "Enter the host in Settings, then pull down to see its bundles."
                                : "Keep a video for the iPhone from the Mac's Dev tab, then pull down."
                        )
                    )
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { id in
                if let bundle = store.bundle(id) {
                    PlayerView(bundle: bundle)
                }
            }
            .refreshable { await store.refresh() }
            .task(id: hostText) {
                store.host = AppSettings.hostURL(hostText)
                await store.refresh()
            }
            .onChange(of: path) { openID = path.first ?? "" }
            .onAppear {
                if let id = reopen.take(openID), store.bundle(id) != nil { path = [id] }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: BundleStore.Item) -> some View {
        if let bundle = store.bundle(item.id) {
            NavigationLink(value: bundle.id) {
                BundleRow(item: item, download: nil, onDownload: nil)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(item.id) }
            }
        } else if let download = store.downloads[item.id] {
            BundleRow(item: item, download: download, onDownload: nil)
                .swipeActions(edge: .trailing) {
                    Button("Cancel", systemImage: "xmark", role: .destructive) { store.delete(item.id) }
                }
        } else {
            BundleRow(item: item, download: nil) { store.download(item.id) }
        }
    }
}

/// The video to go back to when the app starts again: asked each time the
/// list appears, as it does after Back, and answering only the first time.
struct ReopenOnce {
    private var isTaken = false

    mutating func take(_ saved: String) -> String? {
        defer { isTaken = true }
        return isTaken || saved.isEmpty ? nil : saved
    }
}

struct BundleRow: View {
    let item: BundleStore.Item
    let download: BundleStore.Download?
    let onDownload: (() -> Void)?

    /// Length, size, and how many captions when the host said.
    private var detail: String {
        var parts = [BundleNaming.length(item.duration), BundleNaming.size(item.size)]
        if let lines = item.lines { parts.append("\(lines) lines") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .lineLimit(2)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let download {
                    ProgressView(value: download.fraction)
                }
            }
            Spacer()
            if let download {
                Text(download.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if item.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Downloaded")
            } else if let onDownload {
                Button("Download", systemImage: "arrow.down.circle", action: onDownload)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
