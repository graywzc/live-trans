import XCTest
@testable import LiveTransMobile

/// The install's expiry, read from its provisioning profile.
final class InstallExpiryTests: XCTestCase {
    /// The plist is cut out of the signed blob around it and its
    /// ExpirationDate read; a blob without one gives nothing.
    func testTheExpiryIsReadFromTheProfilesPlist() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Name</key><string>iOS Team Provisioning Profile: example.app</string>
            <key>ExpirationDate</key><date>2026-11-20T18:30:00Z</date>
            </dict></plist>
            """
        var profile = Data([0x30, 0x82, 0x0f, 0x00, 0x06, 0x09])  // the CMS wrapping before it
        profile.append(Data(plist.utf8))
        profile.append(Data([0xa0, 0x82, 0x0b, 0x00]))  // and the signature after
        let expiry = try XCTUnwrap(InstallExpiry.date(inProfile: profile))
        XCTAssertEqual(expiry, ISO8601DateFormatter().date(from: "2026-11-20T18:30:00Z"))
        XCTAssertNil(InstallExpiry.date(inProfile: Data("no profile here".utf8)))
    }

    /// Days left, said and colored: green a week out, orange at two days
    /// or fewer, red once passed.
    func testTheDaysLeftAreSaidAndColoredByHowSoon() {
        let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func days(_ hours: Double) -> Int {
            InstallExpiry.days(until: now.addingTimeInterval(hours * 3600), from: now, calendar: calendar)
        }
        XCTAssertEqual(days(6 * 24 + 5), 6)
        XCTAssertEqual(days(30), 1)
        XCTAssertEqual(days(-30), -1)
        XCTAssertEqual(InstallExpiry.remaining(6), "in 6 days")
        XCTAssertEqual(InstallExpiry.remaining(1), "in 1 day")
        XCTAssertEqual(InstallExpiry.remaining(-1), "expired")
        XCTAssertEqual(InstallExpiry.color(6), .green)
        XCTAssertEqual(InstallExpiry.color(2), .orange)
        XCTAssertEqual(InstallExpiry.color(-1), .red)
    }
}
