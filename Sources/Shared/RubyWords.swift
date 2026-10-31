import Foundation

/// The word a piece of ruby text belongs to. Furigana.annotate splits a
/// word to put the reading over its kanji alone and marks the later pieces
/// `continuesWord`; a double-click on the Mac and a long press on the
/// phone take the whole word, whichever piece was hit.
enum RubyWords {
    /// The tokens of the word the token at `index` is part of: from the
    /// first piece back to the one before a continuation to the last piece
    /// that continues it. Empty for an index outside the tokens.
    static func word(at index: Int, in tokens: [RubyToken]) -> Range<Int> {
        guard tokens.indices.contains(index) else { return index..<index }
        var first = index
        while first > 0, tokens[first].continuesWord { first -= 1 }
        var last = index
        while last + 1 < tokens.count, tokens[last + 1].continuesWord { last += 1 }
        return first..<(last + 1)
    }

    /// The word's text: its pieces joined.
    static func text(of range: Range<Int>, in tokens: [RubyToken]) -> String {
        tokens[range].map(\.base).joined()
    }
}
