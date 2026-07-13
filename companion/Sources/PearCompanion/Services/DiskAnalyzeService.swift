import Foundation

// MARK: - Byte formatting

/// Decimal (1000-based) byte formatting that mirrors the CLI's
/// `internal/units.BytesSI` (Finder/diskutil style): "512 B", "1.5 kB",
/// "1.0 GB". Kept as a standalone type so the format is unit-testable.
enum ByteFormat {
    static func si(_ bytes: Int64) -> String {
        if bytes < 0 { return "0 B" }
        let unit: Int64 = 1000
        if bytes < unit { return "\(bytes) B" }

        var div = unit
        var exp = 0
        var n = bytes / unit
        while n >= unit {
            div *= unit
            exp += 1
            n /= unit
        }

        let suffixes = ["k", "M", "G", "T", "P", "E"]
        let suffix = exp < suffixes.count ? suffixes[exp] : suffixes[suffixes.count - 1]
        let value = Double(bytes) / Double(div)
        return String(format: "%.1f %@B", value, suffix)
    }
}

// MARK: - View models

/// One row in the analysis: a directory or file with its measured size.
struct DiskEntry: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    /// True when the CLI flags the entry as reclaimable (`cleanable`) or as a
    /// cleanup insight in the overview (`insight`).
    let cleanable: Bool
    let lastAccess: String?
}

/// A single large file surfaced under "Largest files".
struct DiskFile: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let size: Int64
}

// MARK: - Service

/// Drives `pear analyze --json`. Runs the binary off the main thread, decodes
/// the result, and publishes sorted entries + totals + loading/error state so
/// the view stays declarative. Soft-fails (an error message) when the CLI is
/// missing or the scan times out.
@MainActor
final class DiskAnalyzeService: ObservableObject {
    @Published private(set) var entries: [DiskEntry] = []
    @Published private(set) var largeFiles: [DiskFile] = []
    @Published private(set) var totalSize: Int64 = 0
    /// nil while showing the storage overview; a filesystem path once drilled in.
    @Published private(set) var currentPath: String?
    @Published private(set) var isOverview = true
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// Upper bound so a stuck scan can't hang the UI forever.
    private nonisolated static let timeoutSeconds: Double = 25

    func scan(path: String?) async {
        guard let binary = PearStatsService.pearBinary() else {
            entries = []
            largeFiles = []
            totalSize = 0
            isLoading = false
            errorMessage = "Install the pear CLI to analyze disk usage."
            return
        }

        isLoading = true
        errorMessage = nil

        let result = await Self.runAnalyze(binary: binary, path: path)
        switch result {
        case .failure(let scanError):
            errorMessage = scanError.message
        case .success(let data):
            if let output = try? JSONDecoder().decode(AnalyzeJSON.self, from: data) {
                apply(output)
            } else {
                errorMessage = "Couldn't read the analyzer output."
            }
        }
        isLoading = false
    }

    private func apply(_ output: AnalyzeJSON) {
        isOverview = output.overview
        currentPath = output.overview ? nil : output.path

        entries = output.entries
            .map {
                DiskEntry(
                    name: $0.name,
                    path: $0.path,
                    size: $0.size,
                    isDir: $0.isDir,
                    cleanable: ($0.cleanable ?? false) || ($0.insight ?? false),
                    lastAccess: $0.lastAccess
                )
            }
            .sorted { $0.size > $1.size }

        largeFiles = (output.largeFiles ?? [])
            .map { DiskFile(name: $0.name, path: $0.path, size: $0.size) }
            .sorted { $0.size > $1.size }

        totalSize = output.totalSize
    }

    // MARK: Process

    private enum ScanError: Error {
        case timedOut
        case failed

        var message: String {
            switch self {
            case .timedOut: return "The scan took too long and was stopped."
            case .failed: return "Couldn't analyze this location."
            }
        }
    }

    private static func runAnalyze(binary: String, path: String?) async -> Result<Data, ScanError> {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            var arguments = ["analyze", "--json"]
            if let path { arguments.append(path) }
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return .failure(.failed)
            }

            // Watchdog: terminate the scan if it overruns the timeout. The read
            // below then unblocks on EOF and terminationReason marks the signal.
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            if process.terminationStatus == 0 {
                return .success(output)
            }
            return process.terminationReason == .uncaughtSignal ? .failure(.timedOut) : .failure(.failed)
        }.value
    }
}

// MARK: - Decoding

/// Matches `pear analyze --json`. `cleanable`/`insight` and `large_files`/
/// `total_files` are optional because they appear only in some scan modes.
private struct AnalyzeJSON: Decodable {
    let path: String
    let overview: Bool
    let entries: [Entry]
    let largeFiles: [FileEntry]?
    let totalSize: Int64
    let totalFiles: Int64?

    struct Entry: Decodable {
        let name: String
        let path: String
        let size: Int64
        let isDir: Bool
        let cleanable: Bool?
        let insight: Bool?
        let lastAccess: String?

        enum CodingKeys: String, CodingKey {
            case name, path, size, insight, cleanable
            case isDir = "is_dir"
            case lastAccess = "last_access"
        }
    }

    struct FileEntry: Decodable {
        let name: String
        let path: String
        let size: Int64
    }

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }
}
