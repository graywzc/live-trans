import SwiftUI

/// What the host is busy with right now for the video ("Audio download",
/// "k2 captioning", "Speaker detection"), right of the Start button. All of
/// it when it fits; else the first and how many more, or only how many,
/// and a click opens the whole list. Each task with a bar in Activity has
/// a swatch of its color there.
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
                    Self.swatch(for: items[0])
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
            Self.swatch(for: item)
            Text(item)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.gray)
    }

    /// A task's swatch: its color on its bar in Activity, striped for the
    /// speakers as their bar is over the stretch being told.
    struct Mark: Equatable {
        let color: Color
        var dashed = false
    }

    static func mark(for item: String) -> Mark? {
        guard JobProgressView.hasBar(item) else { return nil }
        return Mark(color: JobProgressView.color(of: item), dashed: item == "Speaker detection")
    }

    static let swatchWidth: CGFloat = 14

    /// The task's mark, or as much room left empty, so the names line up.
    @ViewBuilder
    static func swatch(for item: String) -> some View {
        if let mark = mark(for: item) {
            let height = JobProgressView.barHeight
            if mark.dashed {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    path.addLine(to: CGPoint(x: swatchWidth, y: height / 2))
                }
                .stroke(mark.color, style: StrokeStyle(lineWidth: height, dash: [4, 3]))
                .frame(width: swatchWidth, height: height)
            } else {
                Capsule().fill(mark.color).frame(width: swatchWidth, height: height)
            }
        } else {
            Color.clear.frame(width: swatchWidth, height: 1)
        }
    }
}
