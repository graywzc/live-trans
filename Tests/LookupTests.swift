import XCTest
@testable import LiveTrans

final class LookupTests: XCTestCase {
    func testLinesBecomeEvents() {
        XCTAssertEqual(
            LookupFormat.event(fromLine: #"{"head": "行く", "r": "いく", "tags": ["常用词", "JLPT N5"]}"#),
            .entry(headword: "行く", reading: "いく", tags: ["常用词", "JLPT N5"])
        )
        XCTAssertEqual(
            LookupFormat.event(fromLine: """
                {"pos": "五段动词・自动词", "def": "去；前往", "note": "", "ex": "学校に行く", "ex_zh": "去学校", "here": true}
                """),
            .sense(Sense(
                id: 0, partOfSpeech: "五段动词・自动词", definition: "去；前往",
                example: "学校に行く", exampleChinese: "去学校", appliesHere: true
            ))
        )
        XCTAssertEqual(
            LookupFormat.event(fromLine: #"{"grammar": "なかった", "explain": "ない 的过去形"}"#),
            .grammar(form: "なかった", explanation: "ない 的过去形")
        )
    }

    func testOtherLinesAreDropped() {
        XCTAssertNil(LookupFormat.event(fromLine: "```json"))
        XCTAssertNil(LookupFormat.event(fromLine: "好的，以下是词条："))
        XCTAssertNil(LookupFormat.event(fromLine: #"{"head": ""}"#))
        XCTAssertNil(LookupFormat.event(fromLine: #"{"head": "行く", "r": "#))
    }

    func testMissingFieldsAreEmpty() {
        XCTAssertEqual(
            LookupFormat.event(fromLine: #"{"def": "去"}"#),
            .sense(Sense(id: 0, partOfSpeech: "", definition: "去"))
        )
    }

    func testPiecesAreJoinedIntoLines() {
        var parser = LookupStreamParser()
        XCTAssertEqual(parser.consume(content: #"{"head": "辛い", "#), [])
        XCTAssertEqual(
            parser.consume(content: "\"r\": \"からい\"}\n{\"def\": \"辣"),
            [.entry(headword: "辛い", reading: "からい", tags: [])]
        )
        XCTAssertEqual(parser.consume(content: "的\"}"), [])
        XCTAssertEqual(parser.finish(), [.sense(Sense(id: 0, partOfSpeech: "", definition: "辣的"))])
        XCTAssertEqual(parser.finish(), [])
    }

    func testSensesGoToTheEntryAboveThem() {
        var lookup = Lookup(id: 0, text: "辛い")
        lookup.apply(.sense(Sense(id: 0, partOfSpeech: "", definition: "没有词头")))
        XCTAssertTrue(lookup.isEmpty)
        lookup.apply(.entry(headword: "辛い", reading: "からい", tags: []))
        lookup.apply(.sense(Sense(id: 0, partOfSpeech: "イ形容词", definition: "辣的")))
        lookup.apply(.sense(Sense(id: 0, partOfSpeech: "イ形容词", definition: "咸的")))
        lookup.apply(.entry(headword: "辛い", reading: "つらい", tags: []))
        lookup.apply(.sense(Sense(id: 0, partOfSpeech: "イ形容词", definition: "痛苦的")))
        lookup.apply(.grammar(form: "イ形容词", explanation: "…"))
        XCTAssertEqual(lookup.entries.map(\.id), [0, 1])
        XCTAssertEqual(lookup.entries[0].senses.map(\.definition), ["辣的", "咸的"])
        XCTAssertEqual(lookup.entries[0].senses.map(\.id), [0, 1])
        XCTAssertEqual(lookup.entries[1].senses.map(\.definition), ["痛苦的"])
        XCTAssertEqual(lookup.grammar.map(\.form), ["イ形容词"])
    }

    func testTheRequestCarriesTheSentence() {
        let messages = LookupFormat.messages(lookingUp: "辛い", in: "このラーメンは辛い。")
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[1]["content"], "句子：このラーメンは辛い。\n选中的文字：辛い")
    }
}
