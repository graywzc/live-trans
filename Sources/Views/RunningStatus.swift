import SwiftUI

/// What the host is busy with right now for the video ("Audio download",
/// "k2 captioning", "Speaker detection"), right of the Start button. All of
/// it when it fits; else the first and how many more, or only how many,
/// and a click opens the whole list. Each task with a place on the video's
/// bar has a swatch drawn as it is there, so its color can be told.
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

    /// How a task is drawn on the video's bar: the audio and each
    /// recognizer's captions on the bar itself, thick; translations and
    /// the speakers in the thin lanes under it, the speakers dashed while
    /// they are being told apart.
    struct Mark: Equatable {
        let color: Color
        let thick: Bool
        var dashed = false
    }

    static let recognizers = ["k2", "nemo", "qwen"]

    static func mark(for item: String) -> Mark? {
        if item == "Audio download" { return Mark(color: VideoBar.fetchedColor, thick: true) }
        if item == "Speaker detection" { return Mark(color: VideoBar.speakersColor, thick: false, dashed: true) }
        for name in recognizers {
            if item == "\(name) captioning" { return Mark(color: VideoBar.color(of: name), thick: true) }
            if item == "Translating \(name) captions" {
                return Mark(color: VideoBar.translatedColor(of: name), thick: false)
            }
        }
        return nil
    }

    static let swatchWidth: CGFloat = 14

    /// The task's mark, or as much room left empty, so the names line up.
    @ViewBuilder
    static func swatch(for item: String) -> some View {
        if let mark = mark(for: item) {
            let height = mark.thick ? 6 : VideoBar.laneHeight
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
