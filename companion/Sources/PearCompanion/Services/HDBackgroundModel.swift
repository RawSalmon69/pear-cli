import CoreML
import ImageIO
import UniformTypeIdentifiers
import Observation
import Foundation
import os

/// A compiled RMBG-2 (BiRefNet) Core ML model plus the inference that turns an
/// image into a soft-alpha cutout — remove.bg-class, on-device. `@unchecked
/// Sendable` because `MLModel.prediction` is thread-safe, so a caller can run
/// `cutout` off the main actor.
///
/// Model: VincentGOURBIN/RMBG-2-CoreML (CC-BY-NC-4.0), from BRIA AI RMBG-2.0
/// (non-commercial). Input [1,3,1024,1024] ImageNet-normalized NCHW; output_3 is
/// a full-res logit mask (sigmoid → 0..1 matte).
final class RMBGModel: @unchecked Sendable {
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
              let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: input])),
              let mask = (out.featureValue(for: "output_3") ?? out.featureValue(for: out.featureNames.sorted().last ?? ""))?.multiArrayValue
        else { return nil }

        let matte = Self.sigmoidMatte(mask, count: N * N)
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
    /// Float16 output) and applies sigmoid to turn logits into a 0..1 matte.
    private static func sigmoidMatte(_ mask: MLMultiArray, count: Int) -> [Float] {
        let base = max(0, mask.count - count)
        var out = [Float](repeating: 0, count: count)
        switch mask.dataType {
        case .float16:
            let p = mask.dataPointer.bindMemory(to: Float16.self, capacity: mask.count)
            for i in 0..<count { out[i] = 1.0 / (1.0 + expf(-Float(p[base + i]))) }
        case .float32:
            let p = mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)
            for i in 0..<count { out[i] = 1.0 / (1.0 + expf(-p[base + i])) }
        default:
            for i in 0..<count { out[i] = 1.0 / (1.0 + expf(-mask[base + i].floatValue)) }
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
/// from Hugging Face on request, tracks state for the settings UI, compiles it
/// once per launch, and can delete it to reclaim the ~233MB. Singleton so the
/// settings view and the (static-call) removal sites share one instance without
/// threading it through every service.
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
    /// Compiled model when ready+enabled, else nil. Sendable, so removal sites
    /// can hand it to an off-main `Task`. nil ⇒ callers use the Vision fallback.
    private(set) var model: RMBGModel?

    /// The download's approximate size, for the opt-in notice.
    static let downloadBytes = 244 * 1024 * 1024
    static var downloadSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadBytes), countStyle: .file)
    }

    private let logger = Logger(subsystem: CoupleKey.service, category: "bgremove-hd")
    private var downloadTask: Task<Void, Never>?

    // Hugging Face source (the original host — we don't re-publish it).
    private static let hfBase =
        "https://huggingface.co/VincentGOURBIN/RMBG-2-CoreML/resolve/main/RMBG-2-native-int8.mlpackage"
    private static let files = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]
    private static let weightsBytes: Int64 = 241_333_920 // integrity check

    private var modelDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PearCompanion/Models/RMBG-2-native-int8.mlpackage", isDirectory: true)
    }

    /// Whether the model files are present and complete on disk.
    var isDownloaded: Bool {
        let weights = modelDir.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        guard let size = try? FileManager.default.attributesOfItem(atPath: weights.path)[.size] as? Int64
        else { return false }
        return size == Self.weightsBytes
    }

    /// Called on launch and when the toggle flips on: if downloaded, compile the
    /// model off-main and go ready; else reflect absence. No-op if already busy.
    func prepare() {
        if isDownloaded {
            if model == nil { compile() } else { state = .ready }
        } else {
            state = .absent
        }
    }

    private func compile() {
        // Guard only against a re-entrant compile (already preparing). It MUST
        // run from the download-completion path, where state is still
        // .downloading(1.0) — guarding on .downloading there left the model
        // downloaded-but-never-activated (stuck on a full bar).
        if case .preparing = state { return }
        state = .preparing
        let dir = modelDir
        Task { [weak self] in
            // Build the Sendable RMBGModel wrapper inside the detached task —
            // MLModel itself isn't Sendable, so it must not cross the boundary.
            let built: RMBGModel? = await Task.detached(priority: .userInitiated) {
                guard let url = try? MLModel.compileModel(at: dir) else { return nil }
                let cfg = MLModelConfiguration()
                // CPU-only, deliberately. Measured on this model:
                //  • .all         → Neural Engine compile takes MINUTES (hangs "Preparing…")
                //  • .cpuAndGPU   → loads in ~5s but the GPU MISCOMPUTES this int8 model
                //                   (garbage mask, background not removed)
                //  • .cpuOnly     → ~4s load, ~2s inference, and CORRECT output
                // CPU is the reference backend here: correct and fast.
                cfg.computeUnits = .cpuOnly
                guard let m = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
                return RMBGModel(model: m)
            }.value
            guard let self else { return }
            if let built {
                self.model = built
                self.state = .ready
            } else {
                self.state = .failed("Could not load the model.")
            }
        }
    }

    /// Downloads the model files from Hugging Face with progress, verifies the
    /// weights size, then compiles. Safe to call repeatedly.
    func download() {
        guard downloadTask == nil else { return }
        state = .downloading(0)
        let dir = modelDir
        downloadTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // The two tiny files first (manifest + spec, ~3MB) — no bar.
                for rel in Self.files.dropLast() { try await Self.fetchSimple(rel, into: dir) }
                // Then the 230MB weights with real progress driving the bar.
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
                if self.isDownloaded { self.compile() }
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

    /// Deletes the on-disk model and drops the loaded one, reclaiming the space.
    func remove() {
        downloadTask?.cancel(); downloadTask = nil
        model = nil
        try? FileManager.default.removeItem(at: modelDir)
        state = .absent
    }

    /// The model to use right now: only when the user opted in AND it's ready.
    var activeModel: RMBGModel? {
        (Prefs.hdBackgroundRemoval && state == .ready) ? model : nil
    }

    // MARK: - Download plumbing

    private static func fetchSimple(_ rel: String, into dir: URL) async throws {
        guard let url = URL(string: "\(hfBase)/\(rel)") else { throw URLError(.badURL) }
        let dest = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func fetchWithProgress(
        _ rel: String, into dir: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: "\(hfBase)/\(rel)") else { throw URLError(.badURL) }
        let dest = dir.appendingPathComponent(rel)
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
