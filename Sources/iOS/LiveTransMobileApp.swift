import SwiftUI
import UIKit

/// The iPhone companion: videos captioned on the Mac, kept on the GPU host
/// as bundles, fetched over the tailnet and watched here.
@main
struct LiveTransMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: MobileAppDelegate
    @State private var store: BundleStore

    init() {
        AppSettings.registerDefaults()
        _store = State(initialValue: BundleStore(
            host: nil, root: BundleStore.documentsRoot, configuration: BundleStore.backgroundConfiguration
        ))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Library", systemImage: "books.vertical") {
                    LibraryView()
                }
                Tab("Settings", systemImage: "gearshape") {
                    MobileSettingsView()
                }
            }
            .environment(store)
        }
    }
}

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    /// A download finished while the app was not running: the system
    /// launches it to hear the session out, and is told when it has.
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundTransfer.completion = completionHandler
    }
}

/// The system's completion handler for the download session's events,
/// called once the session has delivered them.
@MainActor
enum BackgroundTransfer {
    static var completion: (() -> Void)?

    static func finish() {
        completion?()
        completion = nil
    }
}
