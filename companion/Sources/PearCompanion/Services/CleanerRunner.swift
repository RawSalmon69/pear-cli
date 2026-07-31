import Foundation
import Observation

/// Runs `pear clean` / `pear optimize` headless and streams output for the
/// native progress panel — no Terminal window. Stdin is /dev/null, so the
/// CLI takes its non-interactive path: user-level cleanup proceeds, and
/// anything needing admin either pops the CLI's own native auth dialog
/// (optimize) or is skipped (clean's system caches — unless the
/// Include-system-caches setting passes `--system`, which pops the CLI's
/// native auth dialog).
@MainActor
@Observable
final class CleanerRunner {
    enum Phase: Equatable {
        case idle
        case running(command: String)
        case finished(command: String, exitCode: Int32)
        /// No usable `pear` on this Mac — not installed, or too old for the
        /// flags this app passes. Carries which, so the panel can say so.
        case unavailable(PearCLI)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""

    @ObservationIgnored private var process: Process?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// clean gets --system when the user opted in; optimize already pops its
    /// own native auth dialog for admin tasks and takes no flag.
    nonisolated static func arguments(for command: String, includeSystemCaches: Bool) -> [String] {
        guard command == "clean", includeSystemCaches else { return [command] }
        return [command, "--system"]
    }

    func run(command: String) {
        guard !isRunning else { return }
        let cli = PearStatsService.resolveCLI()
        guard case .ready(let binary) = cli else {
            phase = .unavailable(cli)
            return
        }

        transcript = ""
        phase = .running(command: command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.arguments(
            for: command, includeSystemCaches: Prefs.cleanIncludeSystemCaches)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1" // CLI honors no-color.org
        // Pinned PATH, not the inherited one. `pear clean --system` resolves
        // `sudo`, `osascript` and `rm` through PATH, and any code running as the
        // user can rewrite a GUI app's inherited PATH with `launchctl setenv` —
        // which would let it supply the binary that draws Pear's admin-password
        // dialog. Nothing the CLI needs lives outside these four directories.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Partial-read carry-over. The pipe invokes the handler serially on its
        // own queue, so single-threaded access to `data` is guaranteed;
        // @unchecked Sendable documents that this closure is its sole owner.
        let carry = StreamBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            carry.data.append(data)
            let chunk = CleanerRunner.decodeStreaming(buffer: &carry.data)
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.append(chunk) }
        }

        process.terminationHandler = { [pipe] process in
            let code = process.terminationStatus
            // Drain what is still sitting in the pipe HERE, on the way out, and
            // deliver it together with the final phase in one main-actor hop.
            // Chunk hops and this hop were enqueued from different queues, so a
            // burst still buffered at exit (usually the reclaimed-space summary)
            // could land *after* the panel already said "finished".
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            carry.data.append(remaining)
            let tail = CleanerRunner.decodeStreaming(buffer: &carry.data)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !tail.isEmpty { self.append(tail) }
                self.process = nil
                self.phase = .finished(command: command, exitCode: code)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
            transcript = "Couldn't start the pear CLI: \(error.localizedDescription)"
            phase = .finished(command: command, exitCode: -1)
        }
    }

    /// Stops the run for real. SIGTERM first, because the CLI traps INT/TERM and
    /// tidies up after itself — but bash defers a trap handler until the running
    /// foreground command returns, so a multi-minute `find … -delete` sweep meant
    /// the panel kept spinning and the cleanup kept going. So: escalate to
    /// SIGKILL if it is still alive after a short grace period.
    ///
    /// Killing the script stops further destructive commands being spawned. One
    /// already-running root sweep (the CLI's own `sudo -n rm`) is out of reach —
    /// a user-level process cannot signal a root child — but those are per-target
    /// and short, so this bounds the damage at "the one in flight".
    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let process = self.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Called from `applicationWillTerminate`: quitting Pear must not leave a
    /// privileged `pear clean --system` running with no window, no transcript and
    /// no way to stop it. Blocking (briefly) on purpose — the app is going away,
    /// and an async cancel would not outlive it.
    func terminateForQuit() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // Same reasoning as `cancel()`, minus the luxury of an async wait.
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Longest transcript kept in memory. A `clean` over a large machine emits a
    /// lot, and the panel only ever shows the tail — an uncapped `String` grew for
    /// the whole run.
    static let transcriptLimit = 200_000

    private func append(_ chunk: String) {
        transcript += Self.stripControl(chunk)
        if transcript.count > Self.transcriptLimit {
            transcript = Self.trimmed(transcript, to: Self.transcriptLimit)
        }
    }

    /// Keeps the last `limit` characters, cut at a line boundary so the panel
    /// never shows half a line. Pure, so the trim is testable.
    nonisolated static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = String(text.suffix(limit))
        guard let newline = tail.firstIndex(of: "\n") else { return tail }
        return String(tail[tail.index(after: newline)...])
    }

    /// Decodes the longest valid UTF-8 prefix of `buffer`, leaving any trailing
    /// bytes of an incomplete multibyte sequence behind for the next read. A
    /// codepoint split across a read boundary would otherwise make
    /// `String(data:encoding:)` reject the whole chunk and silently drop real
    /// CLI output (e.g. a "✓" whose 3 bytes land in two reads).
    nonisolated static func decodeStreaming(buffer: inout Data) -> String {
        if let whole = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return whole
        }
        // The full buffer failed. A UTF-8 codepoint is at most 4 bytes, so an
        // incomplete trailing sequence is at most 3 bytes: trim from the end
        // until a valid prefix decodes, keeping the tail for the next read.
        let maxTail = min(3, buffer.count)
        for drop in 1...maxTail {
            let cut = buffer.count - drop
            if let decoded = String(data: Data(buffer.prefix(cut)), encoding: .utf8) {
                buffer.removeFirst(cut)
                return decoded
            }
        }
        // Not a boundary split — the leading bytes are genuinely invalid.
        // Decode lossily and clear so the stream can never stall on them.
        let salvaged = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return salvaged
    }

    /// NO_COLOR removes colors, but belt-and-braces strip any remaining ANSI
    /// escapes and carriage-return rewrites so the transcript stays readable.
    nonisolated static func stripControl(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")
        return cleaned
    }
}

/// Carries partial-read bytes between successive `readabilityHandler` calls.
/// The pipe invokes the handler serially on a single queue, so the handler is
/// the only accessor; `@unchecked Sendable` records that we rely on that serial
/// contract rather than a lock.
private final class StreamBuffer: @unchecked Sendable {
    var data = Data()
}
