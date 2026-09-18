import Foundation

struct ServerConfig: Equatable {
    /// An ssh target, as it would be typed after `ssh`. May be an alias that
    /// only exists in ~/.ssh/config.
    var sshHost: String
    var port: Int
    var remoteDir: String
    var remotePython: String
    var idleTimeout: Int

    var launchCommand: String {
        let log = "\(remoteDir)/server.log"
        // setsid plus redirecting all three fds fully detaches the server, so
        // dropping the ssh connection cannot take it down.
        return "cd \(remoteDir) && "
            + "setsid nohup \(remotePython) asr_server.py --host 0.0.0.0 --port \(port) "
            + "--idle-timeout \(idleTimeout) < /dev/null >> \(log) 2>&1 & "
            + "disown; echo started"
    }
}

enum SSH {
    static let baseArguments = ["-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    static func process(host: String, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseArguments + [host, command]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Run a command to completion. Returns nil if ssh could not be started or
    /// exited non-zero.
    static func output(host: String, command: String) async -> String? {
        let process = process(host: host, command: command)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: finished.terminationStatus == 0 ? text : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Keeps the GPU server up while the app is captioning. The server is started
/// detached over ssh, a heartbeat says "still here", /shutdown releases the GPU
/// on a clean stop, and the server's own idle timeout covers a crash or a
/// closed lid.
///
/// Detached matters: an earlier design kept the ssh connection open and let
/// SIGHUP stop the server, and any network blip then killed it mid-session.
actor ServerSession {
    enum SessionError: LocalizedError {
        case invalidHost
        case launchFailed(host: String, reason: String)
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                "Set the GPU server's ssh host in Settings."
            case .launchFailed(let host, let reason):
                "Could not start the GPU server on \(host): \(reason)"
            case .startupTimedOut:
                "The GPU server was started but never became ready. See server.log on the host."
            }
        }
    }

    private static let heartbeatInterval: TimeInterval = 30
    private static let startupTimeout: TimeInterval = 180
    /// Don't hammer ssh when the host is genuinely down.
    private static let recoveryCooldown: TimeInterval = 30

    private let config: ServerConfig
    private var client: ASRClient?
    private var owned = false
    private var heartbeat: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var lastRecoveryAt = Date.distantPast

    init(config: ServerConfig) {
        self.config = config
    }

    /// Start the server if it isn't already running, and return a client for it.
    func start(onProgress: @Sendable (String) -> Void = { _ in }) async throws -> (ASRClient, ServerHealth) {
        let host = config.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw SessionError.invalidHost }

        let address = await resolveAddress(host)
        guard let url = URL(string: "http://\(address):\(config.port)") else {
            throw SessionError.invalidHost
        }
        let client = ASRClient(baseURL: url)
        self.client = client

        if let health = await client.health(timeout: 3) {
            // Someone else (another Mac, say) started it; theirs to stop.
            startHeartbeat(client)
            return (client, health)
        }

        onProgress("Starting GPU server on \(host)…")
        let health = try await launch(client)
        owned = true
        startHeartbeat(client)
        return (client, health)
    }

    /// Try to bring the server back after a failed request. Returns at once;
    /// the restart runs in the background and is rate-limited, so a dead host
    /// costs one ssh attempt per cooldown rather than one per utterance.
    func ensureUp() {
        guard let client, recovery == nil,
              Date().timeIntervalSince(lastRecoveryAt) >= Self.recoveryCooldown
        else { return }
        lastRecoveryAt = Date()
        recovery = Task {
            defer { recovery = nil }
            if await client.health(timeout: 3) != nil { return }  // a transient blip
            if (try? await launch(client)) != nil {
                owned = true
            }
        }
    }

    /// Release the GPU now, if we were the ones who started the server.
    func stop() async {
        heartbeat?.cancel()
        heartbeat = nil
        recovery?.cancel()
        recovery = nil
        if owned, let client {
            await client.shutdown()
            owned = false
        }
    }

    /// The ssh alias may only exist in ~/.ssh/config, so ask the host itself
    /// for an address HTTP can reach rather than assuming DNS knows the alias.
    private func resolveAddress(_ host: String) async -> String {
        let output = await SSH.output(host: host, command: "tailscale ip -4 2>/dev/null | head -1")
        let address = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? host : address
    }

    private func launch(_ client: ASRClient) async throws -> ServerHealth {
        // ssh keeps the session channel open even though the server is
        // detached, so don't wait on it: fire the command, poll for health,
        // then drop the ssh.
        let launcher = SSH.process(host: config.sshHost, command: config.launchCommand)
        let stderr = Pipe()
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = stderr
        do {
            try launcher.run()
        } catch {
            throw SessionError.launchFailed(host: config.sshHost, reason: error.localizedDescription)
        }
        defer {
            if launcher.isRunning { launcher.terminate() }
        }

        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let health = await client.health(timeout: 2) {
                return health
            }
            if !launcher.isRunning, launcher.terminationStatus != 0 {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let reason = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.launchFailed(
                    host: config.sshHost, reason: reason.isEmpty ? "ssh failed" : reason
                )
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw SessionError.startupTimedOut
    }

    /// Without this the server's idle timeout would fire during any quiet
    /// stretch: a paused video produces no transcription requests.
    private func startHeartbeat(_ client: ASRClient) {
        heartbeat?.cancel()
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { return }
                _ = await client.health()
            }
        }
    }
}
