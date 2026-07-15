import Foundation
import Observation

/// Runs `pear clean` / `pear optimize` headless and streams output for the
/// native progress panel — no Terminal window. Stdin is /dev/null, so the
/// CLI takes its non-interactive path: user-level cleanup proceeds, and
/// anything needing admin either pops the CLI's own native auth dialog
/// (optimize) or is skipped (clean's system caches).
@MainActor
@Observable
final class CleanerRunner {
    enum Phase: Equatable {
        case idle
        case running(command: String)
        case finished(command: String, exitCode: Int32)
        case unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""

    @ObservationIgnored private var process: Process?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func run(command: String) {
        guard !isRunning else { return }
        guard let binary = PearStatsService.pearBinary() else {
            phase = .unavailable
            return
        }

        transcript = ""
        phase = .running(command: command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [command]
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1" // CLI honors no-color.org
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.append(chunk) }
        }

        process.terminationHandler = { process in
            let code = process.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    /// SIGTERM; the CLI traps INT/TERM and cleans up after itself.
    func cancel() {
        process?.terminate()
    }

    private func append(_ chunk: String) {
        transcript += Self.stripControl(chunk)
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
