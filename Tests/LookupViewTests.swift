import SwiftUI
import XCTest
@testable import LiveTrans

/// The entry as the panel shows it, at the panel's narrowest: written to
/// SNAPSHOT_DIR to be looked at, and checked for text that lost its height.
@MainActor
final class LookupViewTests: XCTestCase {
    private static let answer = """
        {"head": "辛い", "r": "からい", "tags": ["常用词", "JLPT N5"]}
        {"pos": "イ形容词", "def": "辣的；辛辣的", "note": "形容食物或饮料的味道刺激，通常指辣椒等带来的辣味", "ex": "このカレーは辛い。", "ex_zh": "这个咖喱很辣。", "here": true}
        {"pos": "イ形容词", "def": "咸的", "note": "", "ex": "", "ex_zh": "", "here": false}
        {"head": "辛い", "r": "つらい", "tags": ["常用词"]}
        {"pos": "イ形容词", "def": "痛苦的；难受的；辛苦的", "note": "形容身体或精神上的痛苦、劳累或心情压抑", "ex": "昨日は仕事が辛かった。", "ex_zh": "昨天工作很辛苦。", "here": false}
        {"grammar": "イ形容词 + けど", "explain": "终止形后接接续助词「けど」，表示转折：虽然辣，但是好吃。"}
        """

    func testEntryLaysOutAtThePanelsMinimumWidth() throws {
        var lookup = Lookup(id: 0, text: "辛いけど")
        var parser = LookupStreamParser()
        (parser.consume(content: Self.answer) + parser.finish()).forEach { lookup.apply($0) }
        XCTAssertEqual(lookup.entries.count, 2)

        let width = SidePanelView.minWidth
        let view = LookupView(lookup: lookup, fontSize: 15, isLoading: false)
            .padding()
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .background(Color.black)
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        defer { window.close() }

        // Every text got the height its lines take at the width it got.
        func textViews(in view: NSView) -> [NSTextView] {
            ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
        }
        let texts = textViews(in: hosting)
        XCTAssertGreaterThan(texts.count, 10)
        for text in texts {
            let used = try XCTUnwrap(text.layoutManager).usedRect(for: try XCTUnwrap(text.textContainer))
            XCTAssertLessThanOrEqual(used.height, text.frame.height + 1, text.string)
            XCTAssertLessThanOrEqual(used.width, text.frame.width + 1, text.string)
        }

        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"],
           let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/lookup-entry.png"))
        }
    }
}
