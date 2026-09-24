import WebKit
import XCTest
@testable import LiveTrans

final class ChromeVideoTests: XCTestCase {
    func testResultsNameTheTab() {
        XCTAssertEqual(
            ChromeScript.outcome(fromResult: "playing|567|Episode 12 | example.tv"),
            .controlled(ChromeScript.Tab(id: 567, title: "Episode 12 | example.tv", video: .playing), playing: true)
        )
        XCTAssertEqual(
            ChromeScript.outcome(fromResult: "paused|1173479941|Video"),
            .controlled(ChromeScript.Tab(id: 1_173_479_941, title: "Video", video: .paused), playing: false)
        )
        XCTAssertEqual(ChromeScript.outcome(fromResult: "none"), .noVideo)
        XCTAssertEqual(ChromeScript.outcome(fromResult: "gone"), .gone)
        XCTAssertEqual(ChromeScript.outcome(fromResult: "missing value|1|x"), .noVideo)
    }

    func testListingKeepsEveryTab() {
        let listing = [
            ["1", "1173479941", "paused", "https://example.tv/play/x", "Episode 12 | example"],
            ["1", "1173479942", "", "https://github.com/", "GitHub"],
            ["2", "12", "none", "https://example.com/shop", ""],
        ].map { $0.joined(separator: "\u{1F}") + "\u{1E}" }.joined()
        XCTAssertEqual(ChromeScript.tabs(fromListing: listing), [
            .init(id: 1_173_479_941, window: 1, title: "Episode 12 | example", url: "https://example.tv/play/x", video: .paused, isChecked: true),
            .init(id: 1_173_479_942, window: 1, title: "GitHub", url: "https://github.com/", video: nil, isChecked: false),
            .init(id: 12, window: 2, title: "", url: "https://example.com/shop", video: nil, isChecked: true),
        ])
    }

    func testErrorsSayWhatToTurnOn() {
        XCTAssertEqual(
            ChromeScript.failure(number: 12, message: "Executing JavaScript through AppleScript is turned off.").message,
            "In Chrome, turn on View > Developer > Allow JavaScript from Apple Events."
        )
        XCTAssertTrue(ChromeScript.failure(number: -1743, message: "").message.contains("Automation"))
    }

    func testScriptsCompile() throws {
        var sources = [ChromeScript.listSource, ChromeScript.probeSource(tab: 1_173_479_941)]
        for command: ChromeVideo.Command in [.toggle, .skip(seconds: -5), .skip(seconds: 5)] {
            sources.append(ChromeScript.source(for: command, pinned: nil, preferring: nil))
            sources.append(ChromeScript.source(for: command, pinned: nil, preferring: 1_173_479_941))
            sources.append(ChromeScript.source(for: command, pinned: 1_173_479_941, preferring: 1_173_479_941))
        }
        for source in sources {
            var error: NSDictionary?
            let script = try XCTUnwrap(NSAppleScript(source: source))
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])\n\(source)")
        }
    }

    func testJavaScriptSurvivesQuoting() {
        let quoted = ChromeScript.appleScriptString(#"say "hi" \ bye"#)
        XCTAssertEqual(quoted, #""say \"hi\" \\ bye""#)
    }
}

final class SpaceKeyTests: XCTestCase {
    @MainActor
    func testSpaceTypesOnlyWhereTextIsEdited() {
        let editable = NSTextView()
        XCTAssertTrue(SpaceKey.typesSpace(editable))
        let readOnly = NSTextView()
        readOnly.isEditable = false
        XCTAssertFalse(SpaceKey.typesSpace(readOnly))
        let web = WKWebView()
        let inside = NSView()
        web.addSubview(inside)
        XCTAssertTrue(SpaceKey.typesSpace(web))
        XCTAssertTrue(SpaceKey.typesSpace(inside))
        XCTAssertFalse(SpaceKey.typesSpace(NSWindow()))
        XCTAssertFalse(SpaceKey.typesSpace(nil))
    }
}
