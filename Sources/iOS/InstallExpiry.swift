import Foundation
import SwiftUI

/// When this install stops launching: the expiry of the provisioning
/// profile the app was signed with. The phone app is signed with a free
/// personal team by the nightly refresh on the Mac mini, whose profiles
/// last 7 days; the refresh is meant to keep the date about a week out.
enum InstallExpiry {
    /// The running app's, or nil without an embedded profile (the
    /// simulator, or a build not signed that way).
    static var current: Date? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(date(inProfile:))
    }

    /// The ExpirationDate of a `.mobileprovision`: a signed CMS blob with
    /// a plain XML plist inside, which there is no API to unwrap on the
    /// phone, so the plist is cut out of it and read.
    static func date(inProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<plist".utf8))?.lowerBound,
              let end = data.range(of: Data("</plist>".utf8), in: start..<data.endIndex)?.upperBound,
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start..<end), format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary["ExpirationDate"] as? Date
    }

    /// Whole days from `now` to `expiry`, negative once it has passed.
    static func days(until expiry: Date, from now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: now, to: expiry).day ?? 0
    }

    /// "in 6 days", "in 1 day", "expired".
    static func remaining(_ days: Int) -> String {
        days < 0 ? "expired" : "in \(days) day\(days == 1 ? "" : "s")"
    }

    /// Green while the refresh keeps it a week out, orange at two days or
    /// fewer (the refresh has stopped), red once it has passed.
    static func color(_ days: Int) -> Color {
        days < 0 ? .red : days <= 2 ? .orange : .green
    }
}

/// Settings' row for it, beside the version.
struct InstallExpiryRow: View {
    let expiry: Date

    var body: some View {
        let days = InstallExpiry.days(until: expiry)
        LabeledContent("Install expires") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(expiry, format: .dateTime.month().day().year())
                    .foregroundStyle(InstallExpiry.color(days))
                Text(InstallExpiry.remaining(days))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
