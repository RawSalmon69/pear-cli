import Foundation

enum CommandResult {
    case success(Data)
    case failed
    case timedOut
}

/// Seam for services that shell out to the pear CLI, so tests can feed
/// canned output instead of spawning processes.
protocol CommandRunner: Sendable {
    /// Runs `binary arguments`; stdout on exit 0. A `timeout` (seconds)
    /// terminates an overrunning process and reports `.timedOut`.
    func run(binary: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult
}

struct ProcessRunner: CommandRunner {
    func run(binary: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return .failed
            }

            // Watchdog: terminate the process if it overruns. The read below
            // then unblocks on EOF and terminationReason marks the signal.
            var watchdog: DispatchWorkItem?
            if let timeout {
                let item = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + timeout, execute: item)
                watchdog = item
            }

            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog?.cancel()

            if process.terminationStatus == 0 {
                return .success(output)
            }
            return process.terminationReason == .uncaughtSignal ? .timedOut : .failed
        }.value
    }
}
