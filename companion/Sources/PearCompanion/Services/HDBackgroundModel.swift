import CoreML
import ImageIO
import UniformTypeIdentifiers
import Observation
import Foundation
import os

/// A compiled BEN2 Core ML model plus the inference that turns an image into a
/// soft-alpha cutout — remove.bg-class, on-device. `@unchecked Sendable` because
/// `MLModel.prediction` is thread-safe, so a caller can run `cutout` off the
/// main actor.
///
/// Model: BEN2 Base (PramaLLC, MIT — commercial use OK), converted to Core ML
/// fp16. Input [1,3,1024,1024] ImageNet-normalized NCHW; the single output is a
/// full-res 0..1 sigmoid matte (already sigmoided — do NOT sigmoid again).
final class BEN2Model: @unchecked Sendable {
    private let model: MLModel
    private static let N = 1024
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]
    private static let logger = Logger(subsystem: CoupleKey.service, category: "bgremove-hd")

    init(model: MLModel) { self.model = model }

    /// Transparent-background PNG for `imageData`, or nil on any failure (the
    /// caller then falls back to the Vision cutout).
    func cutout(imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let N = Self.N
        let src = Self.rgba(cg, N, N)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: N), NSNumber(value: N)], dataType: .float32)
        else { return nil }
        let ip = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * N * N)
        for y in 0..<N {
            for x in 0..<N {
                let p = (y * N + x) * 4
                for c in 0..<3 {
                    ip[c * N * N + y * N + x] = (Float(src[p + c]) / 255.0 - Self.mean[c]) / Self.std[c]
                }
            }
        }
        guard let inName = model.modelDescription.inputDescriptionsByName.keys.first,
              let outName = model.modelDescription.outputDescriptionsByName.keys.first,
              let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: input])),
              let mask = out.featureValue(for: outName)?.multiArrayValue
        else { return nil }

        let matte = Self.matte(mask, count: N * N)
        return Self.composite(cg: cg, matte: matte, maskSide: N)
    }

    // MARK: - Pixels

    private static func rgba(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Reads the last `count` elements of `mask` as Float (honoring the model's
    /// Float16 output). BEN2 already outputs a 0..1 sigmoid matte, so this reads
    /// it straight through — no sigmoid (double-sigmoid would wash it out).
    private static func matte(_ mask: MLMultiArray, count: Int) -> [Float] {
        let base = max(0, mask.count - count)
        var out = [Float](repeating: 0, count: count)
        switch mask.dataType {
        case .float16:
            let p = mask.dataPointer.bindMemory(to: Float16.self, capacity: mask.count)
            for i in 0..<count { out[i] = Float(p[base + i]) }
        case .float32:
            let p = mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)
            for i in 0..<count { out[i] = p[base + i] }
        default:
            for i in 0..<count { out[i] = mask[base + i].floatValue }
        }
        return out
    }

    /// Applies `matte` (a `maskSide`×`maskSide` alpha) to the full-resolution
    /// image and encodes a transparent PNG.
    private static func composite(cg: CGImage, matte: [Float], maskSide: Int) -> Data? {
        let (w, h) = (cg.width, cg.height)
        var buf = rgba(cg, w, h)
        for y in 0..<h {
            let my = min(maskSide - 1, y * maskSide / h)
            for x in 0..<w {
                let mx = min(maskSide - 1, x * maskSide / w)
                let a = max(0, min(1, matte[my * maskSide + mx]))
                buf[(y * w + x) * 4 + 3] = UInt8(a * 255)
            }
        }
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let outCG = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, outCG, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// Opt-in manager for the high-quality background-removal model: downloads it
/// from the project's GitHub release on request, tracks state for the settings
/// UI, loads it per cutout, and can delete it to reclaim the disk.
///
/// The model is NEVER held between cutouts: `prepared()` hands out an instance
/// the caller owns and ARC frees when the cutout ends. Measured on an M-series
/// Mac, which is why this shape is cheap rather than a sacrifice:
///  • `MLModel(contentsOf:)` from a cached compile: **0.08s**
///  • `MLModel.compileModel`: 0.24s AND a fresh **196 MB copy into the temp
///    directory on every call** — hence the on-disk compile cache; compiling per
///    cutout would litter 196 MB each time
///  • load + one inference: **+15-20 MB** of phys_footprint, not the ~160 MB a
///    vmmap malloc line suggests. Core ML memory-maps the fp16 weights, so they
///    are clean file-backed pages the kernel can evict, not app dirty memory.
///    A second load+inference cycle costs the same as the first (1.7s vs 1.6s),
///    so holding the model buys almost nothing.
/// The launch-time compile this replaced was the real footprint cost: it churned
/// ~196 MB through the allocator, which then sat on the freed pages.
/// Singleton so the settings view and the (static-call) removal sites share one
/// instance without threading it through every service.
@MainActor
@Observable
final class HDBackgroundModelManager {
    static let shared = HDBackgroundModelManager()

    enum State: Equatable {
        case absent
        case downloading(Double) // fraction 0...1 of the weights file
        case preparing // compiling
        case ready
        case failed(String)
    }

    private(set) var state: State = .absent
    /// The download's approximate size, for the opt-in notice.
    static let downloadBytes = 205 * 1024 * 1024
    static var downloadSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadBytes), countStyle: .file)
    }

    private let logger = Logger(subsystem: CoupleKey.service, category: "bgremove-hd")
    private var downloadTask: Task<Void, Never>?

    // GitHub release host. The .mlpackage is split into flat assets (release
    // assets can't have slashes); each maps to a path we rebuild on disk.
    private static let releaseBase =
        "https://github.com/RawSalmon69/pear-cli/releases/download/ben2-bg-model-v1"
    private static let files: [(rel: String, asset: String)] = [
        ("Manifest.json", "BEN2-Manifest.json"),
        ("Data/com.apple.CoreML/model.mlmodel", "BEN2-model.mlmodel"),
        ("Data/com.apple.CoreML/weights/weight.bin", "BEN2-weight.bin"),
    ]
    private static let weightsBytes: Int64 = 203_771_968 // integrity check

    private var modelDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PearCompanion/Models/BEN2-matting-1024.mlpackage", isDirectory: true)
    }

    /// Whether the model files are present and complete on disk.
    var isDownloaded: Bool {
        let weights = modelDir.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        guard let size = try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int64
        else { return false }
        return size == Self.weightsBytes
    }

    /// The compiled model, kept beside the download. `MLModel.compileModel`
    /// writes a **fresh 196 MB copy into the temp directory on every call**
    /// (measured), so compiling per cutout would litter ~196 MB each time.
    /// Compiled once and moved here, a reload costs 0.08s against 0.24s + a full
    /// copy (both measured on an M-series Mac).
    var compiledDir: URL {
        modelDir.deletingLastPathComponent()
            .appendingPathComponent("BEN2-matting-1024.mlmodelc", isDirectory: true)
    }

    /// Reflects whether the model is on disk. Deliberately does NOT load it:
    /// loaded weights are ~160 MB resident, and the app must not hold that
    /// between cutouts. Cheap enough to call on launch — it stats one file.
    func prepare() {
        guard loadTask == nil else { return } // a load in flight owns `state`
        state = isDownloaded ? .ready : .absent
    }

    /// A model for ONE cutout. Nothing is cached: the caller's reference is the
    /// only one, so ARC frees the ~160 MB of weights the moment that cutout
    /// finishes. That is deliberate (owner's call) — a menu-bar app should not
    /// sit on a neural network between uses, and reloading is 0.08s once the
    /// compile is cached. nil ⇒ the caller falls back to Apple Vision, which is
    /// correct when the user has not opted in or nothing is downloaded.
    func prepared() async -> BEN2Model? {
        guard Prefs.hdBackgroundRemoval, isDownloaded else { return nil }
        return await load()
    }

    /// In-flight load, so two cutouts started at once load once and both wait on
    /// the same result rather than pulling two copies into memory.
    private var loadTask: Task<BEN2Model?, Never>?

    private func load() async -> BEN2Model? {
        if let loadTask { return await loadTask.value }
        state = .preparing
        let dir = modelDir
        let cache = compiledDir
        // Build the Sendable BEN2Model wrapper inside the detached task —
        // MLModel itself isn't Sendable, so it must not cross the boundary.
        let task = Task<BEN2Model?, Never> {
            await Task.detached(priority: .userInitiated) {
                guard let url = Self.compiled(package: dir, cache: cache) else { return nil }
                let cfg = MLModelConfiguration()
                // CPU-only, deliberately. Verified by PyTorch-vs-Core ML parity
                // on this BEN2 model:
                //  • .all (ANE)   → 26s compile AND wrong output (maxΔ 0.89 vs ref)
                //  • .cpuAndGPU   → the GPU MISCOMPUTES it (NaN mask)
                //  • .cpuOnly     → ~1s load, ~1.6s inference, matches ref (fp16-level)
                // CPU is the reference backend here: correct and fast. Same
                // pattern as the old RMBG model — do not "optimize" to ANE/GPU.
                cfg.computeUnits = .cpuOnly
                if let m = try? MLModel(contentsOf: url, configuration: cfg) {
                    return BEN2Model(model: m)
                }
                // A cached compile can go stale — a macOS update can change the
                // format. Drop it and compile once more rather than silently
                // falling back to Vision for the rest of the install's life.
                guard url == cache else { return nil }
                try? FileManager.default.removeItem(at: cache)
                guard let fresh = Self.compiled(package: dir, cache: cache),
                      let m = try? MLModel(contentsOf: fresh, configuration: cfg) else { return nil }
                return BEN2Model(model: m)
            }.value
        }
        loadTask = task
        let built = await task.value
        loadTask = nil
        // Loading takes a moment, and the user can turn the toggle off or press
        // Remove inside it. Re-check rather than handing back weights they just
        // asked to be rid of.
        guard Prefs.hdBackgroundRemoval, isDownloaded else {
            state = isDownloaded ? .ready : .absent
            return nil
        }
        state = built == nil ? .failed("Could not load the model.") : .ready
        return built
    }

    /// The compiled model directory, compiling once if it isn't there yet.
    /// `compileModel` always writes to a NEW temp directory, so its output is
    /// moved into the cache; left alone it accumulates ~196 MB per compile.
    nonisolated private static func compiled(package: URL, cache: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: cache.path) { return cache }
        guard let temp = try? MLModel.compileModel(at: package) else { return nil }
        do {
            try fm.createDirectory(at: cache.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: temp, to: cache)
            return cache
        } catch {
            // Could not cache it (disk full, or another load won the race and
            // put it there first). Loading from the temp copy still works.
            return fm.fileExists(atPath: cache.path) ? cache : temp
        }
    }

    /// Downloads the model files from GitHub with progress, verifies the
    /// weights size, then reflects readiness. Safe to call repeatedly.
    func download() {
        guard downloadTask == nil else { return }
        state = .downloading(0)
        let dir = modelDir
        downloadTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // The two tiny files first (manifest + spec, ~1MB) — no bar.
                for file in Self.files.dropLast() { try await Self.fetchSimple(file, into: dir) }
                // Then the ~204MB weights with real progress driving the bar.
                try await Self.fetchWithProgress(Self.files.last!, into: dir) { fraction in
                    Task { @MainActor in
                        if let self, case .downloading = self.state { self.state = .downloading(fraction) }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.state = .failed("Download failed. Check your connection and try again.")
                    self?.logger.error("HD model download failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            await MainActor.run {
                self?.downloadTask = nil
                guard let self else { return }
                // Downloaded, not loaded: the first cutout compiles it.
                if self.isDownloaded { self.prepare() }
                else { self.state = .failed("The download was incomplete."); try? FileManager.default.removeItem(at: dir) }
            }
        }
    }

    /// Bytes downloaded so far, for the "X of Y" label, from the live fraction.
    var progressText: String? {
        guard case .downloading(let f) = state else { return nil }
        let done = Int64(Double(Self.weightsBytes) * f)
        let fmt = ByteCountFormatter()
        return "\(fmt.string(fromByteCount: done)) of \(fmt.string(fromByteCount: Self.weightsBytes))"
    }

    /// Deletes the download AND the compiled copy beside it. Nothing to unload:
    /// no model is ever held between cutouts, so a cutout in flight simply keeps
    /// the instance it already has and the next one falls back to Vision.
    func remove() {
        downloadTask?.cancel(); downloadTask = nil
        try? FileManager.default.removeItem(at: modelDir)
        try? FileManager.default.removeItem(at: compiledDir)
        state = .absent
    }

    // MARK: - Download plumbing

    private static func fetchSimple(_ file: (rel: String, asset: String), into dir: URL) async throws {
        guard let url = URL(string: "\(releaseBase)/\(file.asset)") else { throw URLError(.badURL) }
        let dest = dir.appendingPathComponent(file.rel)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func fetchWithProgress(
        _ file: (rel: String, asset: String), into dir: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: "\(releaseBase)/\(file.asset)") else { throw URLError(.badURL) }
        let dest = dir.appendingPathComponent(file.rel)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let delegate = DownloadProgressDelegate(progress: progress) { cont.resume(with: $0) }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.hold(session)
            session.downloadTask(with: url).resume()
        }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

/// Bridges URLSession's byte-progress + completion callbacks to a continuation.
/// The finished temp file is moved somewhere stable inside the callback (the
/// delegate's `location` is deleted the instant the callback returns).
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var finished = false

    init(progress: @escaping @Sendable (Double) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.progress = progress
        self.completion = completion
    }

    func hold(_ session: URLSession) { self.session = session }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: stable); finish(.success(stable)) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
        session?.invalidateAndCancel()
        session = nil
    }
}
