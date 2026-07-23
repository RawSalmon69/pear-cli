import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import os

/// On-device background removal via Vision's foreground-instance mask — the same
/// model Photos/Preview use for "remove background". Offline, no model download,
/// no entitlement. macOS 14+, which the app already requires, so no gating.
///
/// A plain namespace of `nonisolated` statics working purely on `Data`, so a
/// caller can run it off the main actor (`Task.detached { … }`) without ferrying
/// non-Sendable CoreGraphics types across the hop.
enum BackgroundRemovalService {
    private static let logger = Logger(subsystem: CoupleKey.service, category: "bgremove")

    /// Routes to the high-quality BEN2 model when the caller supplies one (the
    /// user opted in and it's downloaded), else the built-in Vision cutout. If
    /// the HD model fails for any reason, falls back to Vision so removal always
    /// produces something.
    static func cutout(imageData: Data, using hd: BEN2Model?) -> Data? {
        if let hd, let out = hd.cutout(imageData: imageData) { return out }
        return cutout(imageData: imageData)
    }

    /// PNG (with transparency) of the foreground subjects in `imageData`, or nil
    /// when Vision finds no foreground instance (caller keeps the original).
    static func cutout(imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cutout(cgImage: cgImage)
    }

    static func cutout(cgImage: CGImage) -> Data? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("background removal failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // No result means no subject was detected — not an error.
        guard let result = request.results?.first else { return nil }
        do {
            let masked = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            return png(from: masked)
        } catch {
            logger.error("mask compositing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The masked buffer carries alpha where the background was removed; render
    /// it to a PNG so the transparency is preserved.
    private static func png(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
