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
        /// Plays from a sentence, in the tab it was heard in.
        case seek(VideoMoment)
    }

    private(set) var state = State.unknown
    /// Why the last command did nothing, for the user to fix.
    var problem: String?

    /// The tab the user chose. Nil means automatic: whichever front tab has a
    /// video.
    private(set) var pinned: ChromeScript.Tab?
    /// The tab the buttons last controlled, whether chosen or found, or in
    /// automatic the one they would control as of the last listing.
    private(set) var linked: ChromeScript.Tab?

    /// What the buttons control now.
    var controlled: ChromeScript.Tab? { pinned ?? linked }
    /// Chrome's tabs, as of the last `refreshTabs`, each marked with its
    /// video once checked.
    private(set) var tabs: [ChromeScript.Tab] = []
    private(set) var isLoadingTabs = false

    private var inFlight = false
    /// Chrome has answered this session, so it's running and LiveTrans is
    /// allowed to ask, and a refresh no one asked for can't bring up the
    /// Automation prompt.
    private var hasReachedChrome = false
    private let queue = DispatchQueue(label: "ChromeVideo")

    /// `completion` is told whether the video did what was asked.
    func send(_ command: Command, completion: (@MainActor (Bool) -> Void)? = nil) {
        // A click while Chrome is still answering would race the first one.
        guard !inFlight, chromeIsRunning() else {
            completion?(false)
            return
        }
        inFlight = true
        let target = if case .seek(let moment) = command { moment.tabID } else { pinned?.id }
        let source = ChromeScript.source(for: command, pinned: target, preferring: linked?.id)
        queue.async {
            let outcome = ChromeScript.run(source)
            Task { @MainActor in
                self.inFlight = false
                if case .controlled = outcome {
                    completion?(true)
                } else {
                    completion?(false)
                }
                if case .seek = command {
                    self.applySeek(outcome)
                } else {
                    self.apply(outcome)
                }
            }
        }
    }

    /// Where the video is at `wall`, for noting when a sentence was heard.
    /// Nil unless LiveTrans may already control Chrome: captioning something
    /// other than a Chrome video must not bring up the Automation prompt, nor
    /// report anything.
    func moment(at wall: Date) async -> VideoMoment? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScript.bundleID).isEmpty
        else { return nil }
        let source = ChromeScript.source(running: ChromeScript.momentJavaScript, pinned: pinned?.id, preferring: linked?.id)
        let known = hasReachedChrome
        let result = await withCheckedContinuation { continuation in
            queue.async {
                guard known || ChromeScript.mayAutomateWithoutAsking() else {
                    return continuation.resume(returning: nil as String?)
                }
                continuation.resume(returning: try? ChromeScript.runForText(source).get())
            }
        }
        guard let result, let moment = ChromeScript.moment(fromResult: result, at: wall) else { return nil }
        hasReachedChrome = true
        return moment
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
        list(reportingProblems: true)
    }

    /// For keeping the label current: says nothing, and does nothing until
    /// the user has used the video controls.
    func refreshTabsQuietly() {
        guard !isLoadingTabs, hasReachedChrome,
              !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeScript.bundleID).isEmpty
        else { return }
        list(reportingProblems: false)
    }

    private func list(reportingProblems: Bool) {
        isLoadingTabs = true
        let source = ChromeScript.listSource
        queue.async {
            let listing = ChromeScript.runForText(source)
            Task { @MainActor in
                switch listing {
                case .success(let text):
                    self.hasReachedChrome = true
                    let listed = ChromeScript.tabs(fromListing: text)
                    if self.pinned == nil {
                        self.linked = ChromeScript.automaticTarget(in: listed, remembered: self.linked?.id)
                        self.state = self.linked?.video ?? .unknown
                    }
                    self.checkRemaining(listed)
                case .failure(let failure):
                    self.isLoadingTabs = false
                    if reportingProblems { self.problem = failure.message }
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
        checkNext(listed.filter { !$0.isChecked }.map(\.id))
    }

    /// One tab per trip through the queue, so a button pressed meanwhile
    /// waits for at most one check rather than all of them.
    private func checkNext(_ ids: [Int]) {
        guard let id = ids.first else {
            isLoadingTabs = false
            return
        }
        queue.async {
            let video = ChromeScript.probe(tab: id)
            Task { @MainActor in
                if let index = self.tabs.firstIndex(where: { $0.id == id }) {
                    self.tabs[index].video = video
                    self.tabs[index].isChecked = true
                    if id == self.pinned?.id { self.state = video ?? .unknown }
                }
                self.checkNext(Array(ids.dropFirst()))
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
            hasReachedChrome = true
            linked = tab
            // Keep what the listing knew; the title may have changed with
            // the next episode.
            if pinned?.id == tab.id { pinned?.title = tab.title }
            state = playing ? .playing : .paused
        case .noVideo:
            state = .unknown
            problem = pinned == nil
                ? "No video found. Bring the video's tab to the front of its Chrome window, or choose the tab from the menu."
                : "The chosen tab has no video."
        case .gone:
            pin(nil)
            problem = "The chosen tab was closed. Back to finding the video automatically."
        case .moved:
            problem = "That tab has moved on to another page."
        case .failed(let message):
            state = .unknown
            problem = message
        }
    }

    /// A seek goes to the sentence's own tab, whatever is chosen, so its tab
    /// being gone says nothing about the chosen one.
    private func applySeek(_ outcome: ChromeScript.Outcome) {
        switch outcome {
        case .gone:
            problem = "The tab this sentence was heard in has been closed."
        case .noVideo:
            problem = "The tab this sentence was heard in has no video now."
        case .controlled(let tab, _):
            let shown = state
            apply(outcome)
            // The buttons stay on the chosen tab, so keep showing its state.
            if let pinned, pinned.id != tab.id { state = shown }
        default:
            apply(outcome)
        }
    }
}

/// A stretch of a Chrome video: where a sentence was said.
struct VideoMoment: Equatable {
    let tabID: Int
    /// The page, so a tab that has moved on to the next video isn't sought.
    let url: String
    let seconds: Double
    /// Where the sentence ends, so playing it can stop there.
    var end: Double?
    /// Video seconds per second heard.
    var rate: Double = 1

    /// This moment `heard` seconds of listening later.
    func advanced(by heard: TimeInterval) -> VideoMoment {
        VideoMoment(tabID: tabID, url: url, seconds: seconds + heard * rate, rate: rate)
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
        /// The tab in front in its window, the only kind automatic controls.
        var isFront = false
    }

    enum Outcome: Equatable {
        case controlled(Tab, playing: Bool)
        case noVideo
        /// The pinned tab no longer exists.
        case gone
        /// The tab sought is on another page now.
        case moved
        case failed(String)
    }

    /// Seeking lands this far before the sentence, so its first word isn't
    /// clipped: the VAD only notices speech once it is under way.
    static let seekLead = 0.5
    /// Playing a sentence runs this far past its end, which is an estimate
    /// and shouldn't cut the last word.
    static let seekTail = 0.3

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
        case .seek(let moment):
            "if (location.href !== \(javaScriptString(moment.url))) return 'moved'; "
                + "const from = Math.max(\(moment.seconds - seekLead), 0); "
                + (moment.end.map { "\(stopScript(at: $0 + seekTail)) " } ?? "")
                + "v.currentTime = from; v.play();"
        }
    }

    /// Pauses `v` once it reaches `end`, so one sentence can be played by
    /// itself. Only one such stop is kept: a fresh seek replaces the last
    /// one's, and it drops itself when the user goes back before the sentence
    /// (another seek or a skip), so it doesn't pause them later out of nowhere.
    static func stopScript(at end: Double) -> String {
        "if (v.liveTransStop) v.removeEventListener('timeupdate', v.liveTransStop); "
            + "v.liveTransStop = () => { if (v.currentTime >= \(end)) { v.pause(); } "
            + "if (v.currentTime >= \(end) || v.currentTime < from - 1) "
            + "{ v.removeEventListener('timeupdate', v.liveTransStop); v.liveTransStop = null; } }; "
            + "v.addEventListener('timeupdate', v.liveTransStop);"
    }

    /// Where the video is and when that was, so the caller can work back to
    /// when a sentence started: "<state> <time> <epoch seconds> <rate> <url>",
    /// the url encoded so it holds no space or "|".
    static let momentJavaScript = javaScript(
        "return [v.paused ? 'paused' : 'playing', v.currentTime, Date.now() / 1000, v.playbackRate, "
            + "encodeURIComponent(location.href)].join(' ');"
    )

    /// The video's time at `wall`, from a `momentJavaScript` result.
    static func moment(fromResult result: String, at wall: Date) -> VideoMoment? {
        let parts = result.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let id = tabID(parts[1]) else { return nil }
        let fields = parts[0].split(separator: " ")
        guard fields.count == 5, fields[0] == "playing" || fields[0] == "paused",
              let time = Double(fields[1]), let now = Double(fields[2]), let rate = Double(fields[3]),
              let url = String(fields[4]).removingPercentEncoding
        else { return nil }
        // Asked when the sentence started, answered a moment later.
        let elapsed = fields[0] == "playing" ? max(now - wall.timeIntervalSince1970, 0) * rate : 0
        return VideoMoment(tabID: id, url: url, seconds: max(time - elapsed, 0), rate: rate)
    }

    /// Runs the command in the pinned tab, or with none pinned in the front
    /// tab of some window: the one last controlled if it still has a video,
    /// else one playing a video, else one with a paused video, front window
    /// first. Background tabs are only reached by pinning, as a sleeping tab
    /// never answers. Returns "gone", "none" or "<state>|<tab id>|<title>".
    static func source(for command: ChromeVideo.Command, pinned: Int?, preferring remembered: Int?) -> String {
        source(running: javaScript(action(for: command)), pinned: pinned, preferring: remembered)
    }

    /// `source(for:)` with any script from `javaScript`.
    static func source(running script: String, pinned: Int?, preferring remembered: Int?) -> String {
        let probe = appleScriptString(javaScript(""))
        let act = appleScriptString(script)
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

    /// The tab automatic mode would pick, mirroring `source`: the one last
    /// controlled if it's still a front tab with a video, else the first front
    /// tab playing one, else the first with a paused one.
    static func automaticTarget(in tabs: [Tab], remembered: Int?) -> Tab? {
        let candidates = tabs.filter { $0.isFront && $0.video != nil }
        return candidates.first { $0.id == remembered }
            ?? candidates.first { $0.video == .playing }
            ?? candidates.first
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

    /// A JavaScript string literal.
    static func javaScriptString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether LiveTrans may send Chrome Apple Events without the user being
    /// asked. Blocks briefly, so keep it off the main thread.
    nonisolated static func mayAutomateWithoutAsking() -> Bool {
        let chrome = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(chrome.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tabID(_ text: Substring) -> Int? {
        Int(text)
    }

    static func outcome(fromResult result: String) -> Outcome {
        if result == "gone" { return .gone }
        if result.hasPrefix("moved|") { return .moved }
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
                video: video, isChecked: !fields[2].isEmpty, isFront: !fields[2].isEmpty
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
