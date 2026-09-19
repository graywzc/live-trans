import XCTest
@testable import LiveTrans

final class JishoTests: XCTestCase {
    func testSearchURLPercentEncodesJapanese() {
        XCTAssertEqual(
            Jisho.searchURL(for: "食べる")?.absoluteString,
            "https://jisho.org/search/%E9%A3%9F%E3%81%B9%E3%82%8B"
        )
    }

    func testSearchURLKeepsTheWholeSelectionInOnePathComponent() {
        XCTAssertEqual(
            Jisho.searchURL(for: " a/b c?\n")?.absoluteString,
            "https://jisho.org/search/a%2Fb%20c%3F"
        )
    }

    func testNothingToSearchFor() {
        XCTAssertNil(Jisho.searchURL(for: " \n"))
    }
}

final class RubySelectionMapTests: XCTestCase {
    /// 食べる、学校 over two lines, every character 20 wide:
    ///
    ///     食 べる 、      y 10...30
    ///     学校            y 50...70
    private let map = RubySelectionMap(
        tokens: [
            RubyToken(base: "食", reading: "た"),
            RubyToken(base: "べる", continuesWord: true),
            RubyToken(base: "、", gluesToPrevious: true),
            RubyToken(base: "学校", reading: "がっこう"),
        ],
        frames: [
            0: CGRect(x: 0, y: 10, width: 20, height: 20),
            1: CGRect(x: 20, y: 10, width: 40, height: 20),
            2: CGRect(x: 60, y: 10, width: 20, height: 20),
            // The reading is wider than the word, which sits centred under it.
            3: CGRect(x: 10, y: 50, width: 40, height: 20),
        ],
        fontSize: 20
    )

    func testPositionIsTheNearestCharacterBoundary() {
        XCTAssertEqual(map.position(at: CGPoint(x: 4, y: 20)), 0)
        XCTAssertEqual(map.position(at: CGPoint(x: 16, y: 20)), 1)
        XCTAssertEqual(map.position(at: CGPoint(x: 38, y: 20)), 2)
        XCTAssertEqual(map.position(at: CGPoint(x: 58, y: 20)), 3)
    }

    func testPointsOutsideTheTextStillHaveAPosition() {
        XCTAssertEqual(map.position(at: CGPoint(x: -50, y: -50)), 0)
        XCTAssertEqual(map.position(at: CGPoint(x: 500, y: 20)), 4)
        XCTAssertEqual(map.position(at: CGPoint(x: 0, y: 60)), 4)
        XCTAssertEqual(map.position(at: CGPoint(x: 500, y: 500)), 6)
    }

    func testAReadingBelongsToTheLineBelowIt() {
        XCTAssertEqual(map.position(at: CGPoint(x: 31, y: 40)), 5)
    }

    func testDoubleClickTakesTheWholeWord() {
        XCTAssertEqual(map.wordRange(at: CGPoint(x: 5, y: 20)), 0..<3)
        XCTAssertEqual(map.wordRange(at: CGPoint(x: 50, y: 20)), 0..<3)
        XCTAssertEqual(map.wordRange(at: CGPoint(x: 70, y: 20)), 3..<4)
        XCTAssertEqual(map.wordRange(at: CGPoint(x: 30, y: 60)), 4..<6)
        XCTAssertNil(map.wordRange(at: CGPoint(x: 300, y: 20)))
    }

    func testSelectedText() {
        XCTAssertEqual(map.text(in: 0..<3), "食べる")
        XCTAssertEqual(map.text(in: 4..<6), "学校")
    }

    func testHighlightIsOneRectanglePerLine() {
        let rects = map.rects(for: 1..<5)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].minX, 20, accuracy: 0.5)
        XCTAssertEqual(rects[0].maxX, 80, accuracy: 0.5)
        XCTAssertEqual(rects[1].minX, 10, accuracy: 0.5)
        XCTAssertEqual(rects[1].maxX, 30, accuracy: 0.5)
    }

    func testBoundariesFollowGlyphWidths() {
        let fractions = RubySelectionMap.boundaryFractions(of: "iW漢", fontSize: 20)
        XCTAssertEqual(fractions.count, 4)
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted())
        // "i" is much narrower than "W".
        XCTAssertLessThan(fractions[1], fractions[2] - fractions[1])
    }
}
