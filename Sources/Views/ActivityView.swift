import SwiftUI

/// What is going on behind the captions: how this Mac and the GPU server
/// stand now, and under that what each has done, newest at the bottom.
struct ActivityView: View {
    static let symbol = "waveform.path.ecg"

    /// What the two machines are called in the list: this Mac by its own
    /// name, the server by the ssh host it is reached at.
    var macName = ActivityView.macName
    var hostName = ActivityView.hostName(sshHost: AppSettings.serverConfig.sshHost)

    @Environment(ActivityLog.self) private var log
    @Environment(CaptionEngine.self) private var engine
    @Environment(Prefetcher.self) private var prefetch

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(name: macName, color: Self.macColor(engine.status), text: macStatus)
                StatusRow(
                    name: hostName, color: Self.hostColor(engine.status),
                    text: Self.hostStatus(engine.status, job: prefetch.job)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 10)
            Divider()
            if log.shown.isEmpty {
                ContentUnavailableView(
                    "Nothing yet", systemImage: Self.symbol,
                    description: Text("What this Mac and the GPU server do behind the captions is listed here as it happens.")
                )
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(log.shown) { entry in
                                EntryRow(entry: entry, name: entry.machine == .mac ? macName : hostName)
                            }
                        }
                        .padding()
                        // A few lines start at the top, not at the bottom
                        // the scroll is anchored to.
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                    }
                    // Follows the newest line until scrolled away from it.
                    .defaultScrollAnchor(.bottom)
                }
            }
        }
    }

    private var macStatus: String {
        Self.macStatus(engine.status, isSpeaking: engine.isSpeaking, awaited: engine.awaited)
    }

    static let macName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "Mac" }
        let name = String(cString: buffer).split(separator: ".").first.map(String.init) ?? ""
        return name.isEmpty ? "Mac" : name
    }()

    /// "gpu" of "me@gpu"; "GPU" while no host is set.
    static func hostName(sshHost: String) -> String {
        let name = sshHost.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@").last.map(String.init) ?? ""
        return name.isEmpty ? "GPU" : name
    }

    static func macStatus(_ status: CaptionEngine.Status, isSpeaking: Bool, awaited: Int) -> String {
        switch status {
        case .idle: return "Not captioning"
        case .failed(let message): return message
        case .connecting(let message): return message
        case .listening, .reconnecting:
            var parts = [isSpeaking ? "Hearing speech" : "Listening"]
            if awaited > 0 {
                parts.append(awaited == 1 ? "1 utterance awaiting its captions" : "\(awaited) utterances awaiting their captions")
            }
            return parts.joined(separator: " · ")
        }
    }

    static func hostStatus(_ status: CaptionEngine.Status, job: Prefetcher.Job?) -> String {
        switch status {
        case .idle, .failed: return "Not in use"
        case .connecting: return "Starting"
        case .reconnecting: return "Not answering, being restarted"
        case .listening(let models):
            guard let job else { return models }
            return models + "\n" + jobStatus(job)
        }
    }

    /// "Job 1a2b3c running · fetched to 6:52 · captioned to 6:20 of 24:00"
    static func jobStatus(_ job: Prefetcher.Job) -> String {
        var captioned = "captioned to \(CaptionRow.timestamp(job.ready))"
        if let duration = job.duration, duration > 0 {
            captioned += " of \(CaptionRow.timestamp(duration))"
        }
        return [
            "Job \(job.id.prefix(6)) \(job.paused ? "paused" : job.state)",
            "fetched to \(CaptionRow.timestamp(job.fetched))", captioned,
        ].joined(separator: " · ")
    }

    static func macColor(_ status: CaptionEngine.Status) -> Color {
        switch status {
        case .idle: .gray
        case .connecting: .yellow
        case .listening, .reconnecting: .green
        case .failed: .red
        }
    }

    static func hostColor(_ status: CaptionEngine.Status) -> Color {
        switch status {
        case .idle, .failed: .gray
        case .connecting: .yellow
        case .listening: .green
        case .reconnecting: .orange
        }
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// The clear button, by the tab picker.
struct ActivityControls: View {
    @Environment(ActivityLog.self) private var log

    var body: some View {
        Spacer(minLength: 0)
        Button {
            log.showsDetails.toggle()
        } label: {
            Image(systemName: log.showsDetails ? "list.bullet.indent" : "list.bullet")
        }
        .help(log.showsDetails ? "Hide the steps of each hearing" : "Show the steps of each hearing")
        Button(action: log.clear) {
            Image(systemName: "trash")
        }
        .disabled(log.entries.isEmpty)
        .help("Clear the list")
    }
}

private struct StatusRow: View {
    let name: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            MachineName(name: name)
            Text(text)
                .foregroundStyle(.white)
        }
        .font(.caption)
    }
}

private struct EntryRow: View {
    let entry: ActivityLog.Entry
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ActivityView.time.string(from: entry.at))
                .foregroundStyle(.gray)
            MachineName(name: name)
                .foregroundStyle(entry.machine == .mac ? Color.cyan : Color.orange)
            Text(entry.text)
                .foregroundStyle(entry.isDetail ? Color(white: 0.72) : .white)
                .textSelection(.enabled)
        }
        .font(.caption.monospacedDigit())
    }
}

/// One width for both names, so the text after them lines up.
private struct MachineName: View {
    static let width: CGFloat = 44

    let name: String

    var body: some View {
        Text(name)
            .fontWeight(.medium)
            .lineLimit(1)
            .frame(width: Self.width, alignment: .leading)
    }
}
