import XCTest
@testable import LiveTrans

/// The word a piece of ruby text belongs to, as the Mac's double-click and
/// the phone's long press take it.
final class RubyWordsTests: XCTestCase {
    // 歌っている。 as Furigana.annotate splits it: the kanji with its reading,
    // the okurigana continuing the word, then a word of its own and the
    // full stop glued to it.
    private let tokens = [
        RubyToken(base: "歌", reading: "うた"),
        RubyToken(base: "って", continuesWord: true),
        RubyToken(base: "いる"),
        RubyToken(base: "。", gluesToPrevious: true),
    ]

    func testAnyPieceOfASplitWordGivesTheWholeWord() {
        XCTAssertEqual(RubyWords.word(at: 0, in: tokens), 0..<2)
        XCTAssertEqual(RubyWords.word(at: 1, in: tokens), 0..<2)
        XCTAssertEqual(RubyWords.text(of: 0..<2, in: tokens), "歌って")
    }

    func testAWordInOnePieceIsItself() {
        XCTAssertEqual(RubyWords.word(at: 2, in: tokens), 2..<3)
        XCTAssertEqual(RubyWords.text(of: 2..<3, in: tokens), "いる")
    }

    func testGluedPunctuationIsNotPartOfTheWordBeforeIt() {
        XCTAssertEqual(RubyWords.word(at: 3, in: tokens), 3..<4)
        XCTAssertEqual(RubyWords.text(of: 3..<4, in: tokens), "。")
    }

    func testAKanaPrefixBelongsToItsWord() {
        // お茶: the kana prefix first, the kanji continuing it.
        let tea = [RubyToken(base: "お"), RubyToken(base: "茶", reading: "ちゃ", continuesWord: true)]
        XCTAssertEqual(RubyWords.word(at: 1, in: tea), 0..<2)
        XCTAssertEqual(RubyWords.text(of: RubyWords.word(at: 0, in: tea), in: tea), "お茶")
    }

    func testAnIndexOutsideTheTokensGivesNothing() {
        XCTAssertTrue(RubyWords.word(at: 9, in: tokens).isEmpty)
        XCTAssertTrue(RubyWords.word(at: 0, in: []).isEmpty)
    }
}
