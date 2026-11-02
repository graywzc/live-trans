import SwiftUI

/// What the host is busy with right now for the video ("Audio download",
/// "k2 captioning", "Speaker detection"), right of the Start button. All of
/// it when it fits; else the first and how many more, or only how many,
/// and a click opens the whole list.
struct RunningStatus: View {
    let items: [String]

    /// At most this many are listed one under another in the row, which is
    /// as tall as the Start button.
    static let listed = 2

    @State private var isOpen = false

    var body: some View {
        if items.isEmpty {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        } else {
            ViewThatFits(in: .horizontal) {
                if items.count <= Self.listed {
                    list
                } else {
                    summary(naming: true)
                }
                summary(naming: true)
                summary(naming: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Running on the host")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        line(item)
                    }
                }
                .padding(12)
                .fixedSize()
            }
            .onChange(of: items) { if items.isEmpty { isOpen = false } }
        }
    }

    private var list: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                line(item)
            }
        }
        .fixedSize()
        .help(items.joined(separator: "\n"))
    }

    /// One line, clickable for all of them: the first and "+N", or, where
    /// even that does not fit, "N running".
    private func summary(naming: Bool) -> some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                if naming {
                    Text(items[0])
                    if items.count > 1 {
                        Text("+\(items.count - 1)")
                            .padding(.horizontal, 5)
                            .background(.gray.opacity(0.3), in: Capsule())
                    }
                } else {
                    Text("\(items.count) running")
                }
                Image(systemName: "chevron.up")
                    .imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.gray)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show everything running on the host")
    }

    private func line(_ item: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(item)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.gray)
    }
}
