import AppKit

/// Starts the app over as a new process, as quitting and opening it again
/// would: no caption, lookup or analysis is kept, the GPU server is stopped
/// and started afresh, and a page that could not be fetched ahead is tried
/// again.
enum AppRelaunch {
    /// Captioning is stopped first and its release awaited, so the new copy
    /// does not find the old server half-way through shutting down and
    /// attach to it. The new copy is opened a moment after this one has
    /// gone, so the two never run at once.
    @MainActor
    static func relaunch(engine: CaptionEngine) {
        Task { @MainActor in
            await engine.stop().value
            schedule(opening: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        }
    }

    /// Opens `bundle` from a shell that outlives this process.
    static func schedule(opening bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\"", bundle.path]
        try? process.run()
    }
}
