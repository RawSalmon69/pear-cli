import Foundation

/// Interactive region capture shared by the screenshot and OCR tools. Runs
/// the (blocking) `screencapture -i` off the main thread. Returns true only
/// if a file was written — the user hitting Escape writes nothing.
enum ScreenCapture {
    static func region(to url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", url.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    NSLog("Pear: screencapture failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
