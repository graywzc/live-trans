import AppKit
import Observation

/// Plays, pauses and skips the video in a Chrome tab, so watching with
/// LiveTrans on another display doesn't mean carrying the pointer back to the
/// player for every pause.
///
/// Chrome is driven over Apple Events: LiveTrans asks it to run a line of
/// JavaScript against the page's `<video>`. That needs the user to allow it
/// once in Chrome (View > Developer > Allow JavaScript from Apple Events) and
/// once in macOS (Automation).
@MainActor
@Observable
final class ChromeVideo {
    enum State: Equatable {
        case unknown
        case playing
        case paused
    }

    enum Command: Equatable {
        case toggle
        case skip(seconds: Double)
    }

    private(set) var state = State.unknown
    /// Why the last command did nothing, for the user to fix.
    var problem: String?

    /// The tab the user chose. Nil means automatic: whichever front tab has a
    /// video.
    private(set) var pinned: ChromeScript.Tab?
    /// The tab the buttons last controlled, whether chosen or found.
    private(set) var linked: ChromeScript.Tab?
    /// Chrome's tabs, as of the last `refreshTabs`, each marked with its
    /// video once checked.
    private(set) var tabs: [ChromeScript.Tab] = []
    private(set) var isLoadingTabs = false

    private var inFlight = false
    private let queue = DispatchQueue(label: "ChromeVideo")

    func send(_ command: Command) {
        // A click while Chrome is still answering would race the first one.
        guard !inFlight, chromeIsRunning() else { return }
        inFlight = true
        let source = ChromeScript.source(for: command, pinned: pinned?.id, preferring: linked?.id)
        queue.async {
            let outcome = ChromeScript.run(source)
            Task { @MainActor in
                self.inFlight = false
                self.apply(outcome)
            }
        }
    }

    /// Nil goes back to automatic.
    func pin(_ tab: ChromeScript.Tab?) {
        pinned = tab
        linked = tab
        state = tab?.video ?? .unknown
    }

    /// Lists Chrome's tabs with the front tabs checked, then checks the rest
    /// one at a time, publishing each answer as it comes. A tab Chrome has put
    /// to sleep costs a short timeout; it can't be playing anything.
    func refreshTabs() {
        guard !isLoadingTabs, chromeIsRunning() else { return }
        isLoadingTabs = true
        let source = ChromeScript.listSource
        queue.async {
            let listing = ChromeScript.runForText(source)
            Task { @MainActor in
                switch listing {
                case .success(let text):
                    self.checkRemaining(ChromeScript.tabs(fromListing: text))
                case .failure(let failure):
                    self.isLoadingTabs = false
                    self.problem = failure.message
                }
            }
        }
    }

    private func checkRemaining(_ listed: [ChromeScript.Tab]) {
        // Until a tab is checked again, keep what the last refresh found, so
        // reopening the list doesn't empty it.
        let known = Dictionary(tabs.map { ($0.id, $0.video) }, uniquingKeysWith: { first, _ in first })
        tabs = listed.map { tab in
            var tab = tab
            if !tab.isChecked { tab.video = known[tab.id] ?? nil }
            return tab
        }
        let unchecked = listed.filter { !$0.isChecked }.map(\.id)
        queue.async {
            for id in unchecked {
                let video = ChromeScript.probe(tab: id)
                Task { @MainActor in
                    guard let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
                    self.tabs[index].video = video
                    self.tabs[index].isChecked = true
                }
            }
            Task { @MainActor in
                self.isLoadingTabs = false
            }
        }
    }

    private func chromeIsRunning() -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScript.bundleID).isEmpty
        else { return true }
        problem = "Chrome isn't running."
        return false
    }

    private func apply(_ outcome: ChromeScript.Outcome) {
        switch outcome {
        case .controlled(let tab, let playing):
            linked = tab
            // Keep what the listing knew; the title may have changed with
            // the next episode.
            pinned?.title = tab.title
            state = playing ? .playing : .paused
        case .noVideo:
            state = .unknown
            problem = pinned == nil
                ? "No video found. Bring the video's tab to the front of its Chrome window, or choose the tab from the menu."
                : "The chosen tab has no video."
        case .gone:
            pin(nil)
            problem = "The chosen tab was closed. Back to finding the video automatically."
        case .failed(let message):
            state = .unknown
            problem = message
        }
    }
}

/// The AppleScript side, kept free of UI so it can be tested.
///
/// Chrome's tab ids are text. A number written into a script would be read
/// as a real that matches nothing, so ids go in quoted, and tabs are found by
/// comparing ids and then addressed by index.
enum ChromeScript {
    static let bundleID = "com.google.Chrome"

    struct Tab: Identifiable, Equatable {
        let id: Int
        /// 1 is the frontmost window.
        var window = 1
        var title: String
        var url = ""
        /// Nil for a tab with no video, or one not checked yet.
        var video: ChromeVideo.State?
        /// The listing checks only each window's front tab; the rest are
        /// checked afterwards, as a sleeping tab only answers with a timeout.
        var isChecked = false
    }

    enum Outcome: Equatable {
        case controlled(Tab, playing: Bool)
        case noVideo
        /// The pinned tab no longer exists.
        case gone
        case failed(String)
    }

    struct Failure: Error {
        let message: String
    }

    /// Finds the page's main video, the largest one that has loaded, so a
    /// muted preview or an ad thumbnail isn't what gets paused. Evaluates to
    /// "none", or to "playing" / "paused" after running `action` on `v`.
    static func javaScript(_ action: String) -> String {
        """
        (() => { const v = [...document.querySelectorAll('video')]\
        .filter(e => e.readyState > 0)\
        .sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];\
         if (!v) return 'none'; \(action) return v.paused ? 'paused' : 'playing'; })()
        """
    }

    static func action(for command: ChromeVideo.Command) -> String {
        switch command {
        case .toggle:
            "if (v.paused) { v.play(); } else { v.pause(); }"
        case .skip(let seconds):
            "v.currentTime = Math.min(Math.max(v.currentTime + (\(seconds)), 0), v.duration || Infinity);"
        }
    }

    /// Runs the command in the pinned tab, or with none pinned in the front
    /// tab of some window: the one last controlled if it still has a video,
    /// else one playing a video, else one with a paused video, front window
    /// first. Background tabs are only reached by pinning, as a sleeping tab
    /// never answers. Returns "gone", "none" or "<state>|<tab id>|<title>".
    static func source(for command: ChromeVideo.Command, pinned: Int?, preferring remembered: Int?) -> String {
        let probe = appleScriptString(javaScript(""))
        let act = appleScriptString(javaScript(action(for: command)))
        return """
        tell application id "\(bundleID)"
            set pinned to \(pinned.map { "\"\($0)\"" } ?? "missing value")
            set remembered to \(remembered.map { "\"\($0)\"" } ?? "missing value")
            set found to missing value
            if pinned is not missing value then
                repeat with wi from 1 to count windows
                    set ids to (get id of every tab of window wi)
                    repeat with ti from 1 to count ids
                        if item ti of ids = pinned then set found to {wi, ti}
                    end repeat
                end repeat
                if found is missing value then return "gone"
            else
                set playing to missing value
                set paused to missing value
                repeat with wi from 1 to count windows
                    set ti to active tab index of window wi
                    set s to "none"
                    try
                        with timeout of 3 seconds
                            set s to execute tab ti of window wi javascript \(probe)
                        end timeout
                    on error message number code
                        -- A page that can't run scripts (a chrome:// page) is
                        -- skipped, but Chrome refusing them all is the user's to fix.
                        if message contains "turned off" then error message number code
                    end try
                    if s is "playing" or s is "paused" then
                        if remembered is not missing value and (id of tab ti of window wi) = remembered then
                            set found to {wi, ti}
                            exit repeat
                        end if
                        if s is "playing" and playing is missing value then set playing to {wi, ti}
                        if s is "paused" and paused is missing value then set paused to {wi, ti}
                    end if
                end repeat
                if found is missing value then set found to playing
                if found is missing value then set found to paused
                if found is missing value then return "none"
            end if
            set t to tab (item 2 of found) of window (item 1 of found)
            with timeout of 3 seconds
                set s to execute t javascript \(act)
            end timeout
            return (s as text) & "|" & (id of t) & "|" & (title of t)
        end tell
        """
    }

    /// Every tab as "<window>␟<id>␟<front state>␟<url>␟<title>␞", where the
    /// front state is "playing", "paused" or "none" for each window's front
    /// tab and empty for the rest.
    static var listSource: String {
        let probe = appleScriptString(javaScript(""))
        return """
        tell application id "\(bundleID)"
            set fieldEnd to character id 31
            set tabEnd to character id 30
            set out to ""
            repeat with wi from 1 to count windows
                set w to window wi
                set frontIndex to active tab index of w
                set ids to (get id of every tab of w)
                set titles to (get title of every tab of w)
                set urls to (get URL of every tab of w)
                repeat with ti from 1 to count ids
                    set s to ""
                    if ti = frontIndex then
                        set s to "none"
                        try
                            with timeout of 1 second
                                set s to execute tab ti of w javascript \(probe)
                            end timeout
                        end try
                    end if
                    set out to out & wi & fieldEnd & (item ti of ids) & fieldEnd & s & fieldEnd & (item ti of urls) & fieldEnd & (item ti of titles) & tabEnd
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// Checks one tab for a video. Awake tabs answer in milliseconds; a
    /// sleeping one only times out, so the wait is short.
    static func probeSource(tab id: Int) -> String {
        """
        tell application id "\(bundleID)"
            repeat with wi from 1 to count windows
                set ids to (get id of every tab of window wi)
                repeat with ti from 1 to count ids
                    if item ti of ids = "\(id)" then
                        with timeout of 0.2 seconds
                            return execute tab ti of window wi javascript \(appleScriptString(javaScript("")))
                        end timeout
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """
    }

    nonisolated static func probe(tab id: Int) -> ChromeVideo.State? {
        switch runForText(probeSource(tab: id)) {
        case .success("playing"): .playing
        case .success("paused"): .paused
        default: nil
        }
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tabID(_ text: Substring) -> Int? {
        Int(text)
    }

    static func outcome(fromResult result: String) -> Outcome {
        if result == "gone" { return .gone }
        let parts = result.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let id = tabID(parts[1]), parts[0] == "playing" || parts[0] == "paused"
        else { return .noVideo }
        let playing = parts[0] == "playing"
        return .controlled(Tab(id: id, title: String(parts[2]), video: playing ? .playing : .paused), playing: playing)
    }

    static func tabs(fromListing listing: String) -> [Tab] {
        listing.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, let window = Int(fields[0]), let id = tabID(fields[1]) else { return nil }
            let video: ChromeVideo.State? = switch fields[2] {
            case "playing": .playing
            case "paused": .paused
            default: nil
            }
            return Tab(
                id: id, window: window, title: String(fields[4]), url: String(fields[3]),
                video: video, isChecked: !fields[2].isEmpty
            )
        }
    }

    /// What to tell the user about an AppleScript error.
    static func failure(number: Int, message: String) -> Failure {
        switch number {
        case -1743:
            Failure(message: "LiveTrans isn't allowed to control Chrome. Turn it on in System Settings > Privacy & Security > Automation > LiveTrans.")
        case -600, -609:
            Failure(message: "Chrome isn't running.")
        case -1712:
            Failure(message: "Chrome didn't answer in time. If the chosen tab is in the background, Chrome may have put it to sleep: click it once in Chrome.")
        default:
            if message.localizedCaseInsensitiveContains("JavaScript through AppleScript is turned off") {
                Failure(message: "In Chrome, turn on View > Developer > Allow JavaScript from Apple Events.")
            } else {
                Failure(message: "Chrome didn't respond: \(message)")
            }
        }
    }

    nonisolated static func run(_ source: String) -> Outcome {
        switch runForText(source) {
        case .success(let text): outcome(fromResult: text)
        case .failure(let failure): .failed(failure.message)
        }
    }

    /// Blocks until Chrome answers, and the first time until the user has
    /// answered the Automation prompt, so keep it off the main thread.
    nonisolated static func runForText(_ source: String) -> Result<String, Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(Failure(message: "Couldn't build the script."))
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure(failure(
                number: error[NSAppleScript.errorNumber] as? Int ?? 0,
                message: error[NSAppleScript.errorMessage] as? String ?? ""
            ))
        }
        return .success(result.stringValue ?? "")
    }
}
