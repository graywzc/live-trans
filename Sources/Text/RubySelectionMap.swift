import AppKit
import CoreText

/// Where the characters of a laid-out FuriganaText are, so that a pointer
/// position can be turned into a text position and a selection into
/// highlight rectangles. Positions count characters of the joined token bases,
/// which is the caption's text.
struct RubySelectionMap {
    let tokens: [RubyToken]
    /// The frame of each token's base text (not its reading), by token index.
    let frames: [Int: CGRect]
    let fontSize: CGFloat

    /// The text position of each token's first character.
    private let starts: [Int]

    init(tokens: [RubyToken], frames: [Int: CGRect], fontSize: CGFloat) {
        self.tokens = tokens
        self.frames = frames
        self.fontSize = fontSize
        var starts: [Int] = []
        var position = 0
        for token in tokens {
            starts.append(position)
            position += token.base.count
        }
        self.starts = starts
    }

    /// The position between two characters that is nearest to the point. Any
    /// point has one: above the text is its first line, left of a line is that
    /// line's start, and so on, which is what lets a drag leave the text.
    func position(at point: CGPoint) -> Int? {
        guard let line = line(at: point.y), let last = line.last else { return nil }
        for index in line {
            guard let frame = frames[index], point.x < frame.maxX || index == last else { continue }
            let fractions = Self.boundaryFractions(of: tokens[index].base, fontSize: fontSize)
            let target = frame.width > 0 ? (point.x - frame.minX) / frame.width : 0
            let nearest = fractions.indices.min { abs(fractions[$0] - target) < abs(fractions[$1] - target) }
            return starts[index] + (nearest ?? 0)
        }
        return nil
    }

    /// The word under the point, all of it even where it was split into
    /// several tokens.
    func wordRange(at point: CGPoint) -> Range<Int>? {
        guard let line = line(at: point.y),
              let hit = line.first(where: { index in
                  frames[index].map { $0.minX <= point.x && point.x <= $0.maxX } ?? false
              })
        else { return nil }
        var first = hit
        while first > 0, tokens[first].continuesWord { first -= 1 }
        var last = hit
        while last + 1 < tokens.count, tokens[last + 1].continuesWord { last += 1 }
        return starts[first]..<starts[last] + tokens[last].base.count
    }

    /// One rectangle for each line the range touches.
    func rects(for range: Range<Int>) -> [CGRect] {
        var rects: [CGRect] = []
        for index in tokens.indices {
            guard let frame = frames[index] else { continue }
            let count = tokens[index].base.count
            let lower = max(range.lowerBound - starts[index], 0)
            let upper = min(range.upperBound - starts[index], count)
            guard lower < upper else { continue }
            let fractions = Self.boundaryFractions(of: tokens[index].base, fontSize: fontSize)
            let rect = CGRect(
                x: frame.minX + fractions[lower] * frame.width, y: frame.minY,
                width: (fractions[upper] - fractions[lower]) * frame.width, height: frame.height
            )
            // A reading wider than its word leaves a gap between two base
            // texts; the highlight runs through it.
            if let previous = rects.last, Self.sameLine(previous, rect) {
                rects[rects.count - 1] = previous.union(rect)
            } else {
                rects.append(rect)
            }
        }
        return rects
    }

    func text(in range: Range<Int>) -> String {
        let characters = Array(tokens.map(\.base).joined())
        return String(characters[range.clamped(to: 0..<characters.count)])
    }

    /// Token indices of the line that owns a y coordinate. A line owns
    /// everything from the bottom of the line before it, so that pointing at a
    /// reading means the word under it.
    private func line(at y: CGFloat) -> [Int]? {
        var lines: [[Int]] = []
        for index in tokens.indices {
            guard let frame = frames[index] else { continue }
            if let previous = lines.last?.last.flatMap({ frames[$0] }), Self.sameLine(previous, frame) {
                lines[lines.count - 1].append(index)
            } else {
                lines.append([index])
            }
        }
        return lines.first { line in line.contains { (frames[$0]?.maxY ?? 0) > y } } ?? lines.last
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < min(a.height, b.height) / 2
    }

    /// The x of every boundary between characters, first and last included, as
    /// a fraction of the text's width. Kana and kanji are all one width but
    /// captions also carry Latin letters and digits, which are not.
    static func boundaryFractions(of text: String, fontSize: CGFloat) -> [CGFloat] {
        let count = text.count
        guard count > 0 else { return [0] }
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else {
            return (0...count).map { CGFloat($0) / CGFloat(count) }
        }
        var fractions: [CGFloat] = []
        var offset = 0
        for character in text {
            fractions.append(min(max(CTLineGetOffsetForStringIndex(line, offset, nil) / width, 0), 1))
            offset += character.utf16.count
        }
        fractions.append(1)
        return fractions
    }
}
