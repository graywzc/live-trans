import SwiftUI

/// Japanese with readings printed above the kanji. SwiftUI's Text has no ruby
/// support, so each word is a small two-row stack and the words are wrapped
/// like text.
struct FuriganaText: View {
    let tokens: [RubyToken]
    let fontSize: CGFloat

    var body: some View {
        FlowLayout(lineSpacing: fontSize * 0.15) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                VStack(spacing: 0) {
                    // A blank reading still takes its row, so every word has
                    // the same height and the base text shares one baseline.
                    Text(token.reading ?? " ")
                        .font(.system(size: fontSize * 0.5))
                        .foregroundStyle(.secondary)
                    Text(token.base)
                        .font(.system(size: fontSize))
                }
                .fixedSize()
                .layoutValue(key: GluesToPrevious.self, value: token.gluesToPrevious)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tokens.map(\.base).joined())
    }
}

private struct GluesToPrevious: LayoutValueKey {
    static let defaultValue = false
}

/// Left-to-right wrapping. A subview marked GluesToPrevious stays on the same
/// line as the one before it, which keeps 。 and 、 off the start of a line.
private struct FlowLayout: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Runs of subviews that must not be split across lines.
        var groups: [Range<Int>] = []
        for index in subviews.indices {
            if subviews[index][GluesToPrevious.self], let last = groups.popLast() {
                groups.append(last.lowerBound..<index + 1)
            } else {
                groups.append(index..<index + 1)
            }
        }

        var origins = [CGPoint](repeating: .zero, count: subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for group in groups {
            let groupWidth = group.reduce(0) { $0 + sizes[$1].width }
            if x > 0, x + groupWidth > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            for index in group {
                origins[index] = CGPoint(x: x, y: y)
                x += sizes[index].width
                lineHeight = max(lineHeight, sizes[index].height)
            }
            usedWidth = max(usedWidth, x)
        }
        return (origins, CGSize(width: usedWidth, height: y + lineHeight))
    }
}
