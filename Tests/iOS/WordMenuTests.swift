import SwiftUI
import XCTest
@testable import LiveTransMobile

/// The long press on a word: what the one sheet slot shows for each of
/// the menu's items, and the word lifted out whole for the menu.
@MainActor
final class WordMenuTests: XCTestCase {
    private var captions: [Caption] = []

    override func setUp() async throws {
        captions = PlaybackModel.captions(of: try VideoBundle.decode(Data(Fixtures.bundle.utf8)))
    }

    func testTheSheetSlotShowsOneThingAtATimeAndKeepsTheThread() {
        let model = AnalysisSheetModel(analyzer: SentenceAnalyzer(makeClient: { nil }))
        XCTAssertNil(model.presenting)
        XCTAssertFalse(model.isPresented)
        // Grammar: the word looked up as said in its caption, in the
        // thread, which the sheet opens on.
        model.lookUp("歌って", in: captions[0])
        XCTAssertEqual(model.presenting, .thread)
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.analyzer.lookups.map(\.text), ["歌って"])
        XCTAssertEqual(model.analyzer.lookups.first?.sentence, captions[0].japanese)
        XCTAssertEqual(model.analyzer.revealed?.id, model.analyzer.lookups.first?.id, "the sheet turns to the entry")
        XCTAssertTrue(model.analyzer.analyses.isEmpty, "no analysis is made for a word alone")
        // Jisho takes the slot; the thread waits.
        model.showJisho("歌って")
        XCTAssertEqual(model.presenting, .jisho("歌って"))
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(model.analyzer.lookups.count, 1)
        model.showDictionary("いる")
        XCTAssertEqual(model.presenting, .dictionary("いる"))
        XCTAssertNotEqual(AnalysisSheetModel.Presenting.jisho("いる").id, AnalysisSheetModel.Presenting.dictionary("いる").id)
        // The next explanation brings the thread back with the entry in it.
        model.open(captions[1])
        XCTAssertEqual(model.presenting, .thread)
        XCTAssertEqual(model.analyzer.thread.count, 2)
        // Swiped down and left: as before.
        model.isPresented = false
        XCTAssertNil(model.presenting)
        model.end()
        XCTAssertTrue(model.analyzer.lookups.isEmpty)
    }

    /// The word lifted out of its row: all its pieces with their readings,
    /// drawn to a picture (SNAPSHOT_DIR) and checked to have taken room.
    func testTheWordPreviewShowsTheWholeWord() throws {
        let tokens = [
            RubyToken(base: "歌", reading: "うた"),
            RubyToken(base: "って", continuesWord: true),
            RubyToken(base: "いる"),
        ]
        let range = RubyWords.word(at: 1, in: tokens)
        XCTAssertEqual(RubyWords.text(of: range, in: tokens), "歌って")
        let renderer = ImageRenderer(content: WordPreview(tokens: Array(tokens[range]), fontSize: 20))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.width, 60, "two pieces side by side")
        XCTAssertGreaterThan(image.size.height, 40, "a reading over the base text")
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let png = image.pngData() {
            try png.write(to: URL(fileURLWithPath: "\(dir)/phone-word-preview.png"))
        }
    }
}
