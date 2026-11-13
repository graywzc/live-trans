import SwiftUI

/// How far each of the host's tasks has come through the video, in
/// Activity: a bar of its own each, named, so none has to be told by its
/// color, with where the viewer is marked across them all.
struct JobProgressView: View {
    let total: Double
    let tasks: [DevPipeline.Progress]
    var playhead: Double?
    /// The tasks the host is busy with now, named brighter.
    var running: [String] = []

    static let nameWidth: CGFloat = 210
    static let barHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tasks, id: \.task) { task in
                row(task)
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func row(_ task: DevPipeline.Progress) -> some View {
        let reachedEnd = task.reached >= total - 0.5
        let done = reachedEnd && task.holes.isEmpty
        return HStack(spacing: 8) {
            Text(task.task)
                .foregroundStyle(running.contains(task.task) ? Color.white : Color.gray)
                .lineLimit(1)
                .frame(width: Self.nameWidth, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    let color = Self.color(of: task.task)
                    if task.reached > 0 {
                        Capsule().fill(color)
                            .frame(width: max(width * VideoBar.fraction(task.reached, of: total), Self.barHeight))
                    }
                    // Lit too where the video was played ahead of it, from there.
                    ForEach(Array(task.ahead.enumerated()), id: \.offset) { _, stretch in
                        let from = width * VideoBar.fraction(stretch.lowerBound, of: total)
                        Capsule().fill(color)
                            .frame(width: max(width * VideoBar.fraction(stretch.upperBound, of: total) - from, Self.barHeight))
                            .offset(x: from)
                    }
                    // Dark where it left captions out.
                    ForEach(Array(task.holes.enumerated()), id: \.offset) { _, hole in
                        let from = width * VideoBar.fraction(hole.lowerBound, of: total)
                        Rectangle().fill(Color.black)
                            .overlay(Rectangle().fill(Color.white.opacity(0.1)))
                            .frame(width: max(width * VideoBar.fraction(hole.upperBound, of: total) - from, 2))
                            .offset(x: from)
                    }
                    if let stretch = task.underWay {
                        // Striped: under way over that stretch.
                        let from = width * VideoBar.fraction(stretch.lowerBound, of: total)
                        let to = width * VideoBar.fraction(stretch.upperBound, of: total)
                        Path { path in
                            path.move(to: CGPoint(x: from, y: Self.barHeight / 2))
                            path.addLine(to: CGPoint(x: to, y: Self.barHeight / 2))
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: Self.barHeight, dash: [4, 3]))
                    }
                    if let playhead {
                        Rectangle().fill(Color.orange)
                            .frame(width: 2, height: Self.barHeight + 4)
                            .offset(x: width * VideoBar.fraction(playhead, of: total) - 1)
                    }
                }
                .frame(width: width, height: Self.barHeight)
                .frame(maxHeight: .infinity)
            }
            .frame(height: Self.barHeight + 4)
            Text(done ? "done" : reachedEnd ? "gaps" : CaptionRow.timestamp(task.reached))
                .foregroundStyle(.gray)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(task.task)
        .accessibilityValue(done ? "done" : reachedEnd ? "done but for \(task.holes.count) left out"
                            : "to \(CaptionRow.timestamp(task.reached))")
    }

    /// Each task's color, also its swatch in the running list: none of them
    /// the playhead's orange.
    static func color(of task: String) -> Color {
        switch barName(of: task) {
        case "Audio download": fetchedColor
        case "Speech detection": speechColor
        case "Speaker detection": speakersColor
        case "Cutting captions at speaker changes": Color.teal.opacity(0.8)
        default:
            if let name = recognizers.first(where: { task == "\($0) captioning" }) {
                color(ofRecognizer: name)
            } else if let name = recognizers.first(where: { task == "Translating \($0) captions" }) {
                color(ofRecognizer: name).opacity(0.5)
            } else {
                Color.gray
            }
        }
    }

    /// Whether the task has a bar here, and so a swatch in the running list.
    static func hasBar(_ task: String) -> Bool {
        ["Audio download", "Speech detection", "Speaker detection", "Cutting captions at speaker changes"]
            .contains(barName(of: task))
            || recognizers.contains { task == "\($0) captioning" || task == "Translating \($0) captions" }
    }

    /// The bar a running task is shown on: the speech detection the host
    /// names with its finder, "Speech detection (FireRedVAD)", on its one.
    static func barName(of task: String) -> String {
        task.hasPrefix("Speech detection (") ? "Speech detection" : task
    }

    static let recognizers = ["k2", "nemo", "qwen"]
    static let fetchedColor = Color.white.opacity(0.3)
    static let speakersColor = Color.green.opacity(0.7)
    static let speechColor = Color.yellow.opacity(0.75)

    static func color(ofRecognizer name: String) -> Color {
        switch name {
        case "k2": Color.blue.opacity(0.85)
        case "nemo": Color.purple.opacity(0.9)
        default: Color.pink.opacity(0.9)
        }
    }
}
