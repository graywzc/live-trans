import XCTest
@testable import LiveTransMobile

/// The word a piece of ruby text belongs to, as the phone's long press
/// takes it: the same rule as the Mac's double-click, from the shared code.
final class RubyWordsTests: XCTestCase {
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

    func testAWordInOnePieceAndPunctuationStandAlone() {
        XCTAssertEqual(RubyWords.word(at: 2, in: tokens), 2..<3)
        XCTAssertEqual(RubyWords.word(at: 3, in: tokens), 3..<4)
        XCTAssertTrue(RubyWords.word(at: 9, in: tokens).isEmpty)
    }

    func testTheTokenizersOwnSplitsAreTakenWhole() {
        // Whatever the system tokenizer makes of the sentence, every piece
        // it marks as continuing a word belongs to the word before it.
        let annotated = Furigana.annotate("窓の外で鳥が歌っている。")
        for index in annotated.indices where annotated[index].continuesWord {
            let word = RubyWords.word(at: index, in: annotated)
            XCTAssertTrue(word.contains(index - 1), "\(annotated[index].base) continues \(annotated[index - 1].base)")
            XCTAssertFalse(annotated[word.lowerBound].continuesWord, "a word starts with a piece that continues nothing")
        }
    }
}
