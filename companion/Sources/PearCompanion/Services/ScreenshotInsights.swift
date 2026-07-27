import AppKit
import ImageIO
import Observation
import SwiftUI

/// File and image facts for the detail view's Details section. Built from the
/// image header, so making one never decodes the whole capture.
struct ScreenshotDetails: Sendable, Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let format: String
    let capturedAt: Date
    let path: String?
    /// Color profile name (e.g. "sRGB IEC61966-2.1"), when the file carries one.
    let colorProfile: String?
    let bitsPerComponent: Int
    let hasAlpha: Bool
    /// Pixels per inch as recorded in the file; 144 on a Retina capture.
    let dpi: Int

    var dimensionsLabel: String { "\(pixelWidth) × \(pixelHeight)" }

    /// "4.1 MP" — the quick sense of how big a shot really is.
    var megapixelsLabel: String? {
        let pixels = Double(pixelWidth * pixelHeight)
        guard pixels > 0 else { return nil }
        let megapixels = pixels / 1_000_000
        return megapixels < 0.1
            ? nil
            : String(format: megapixels < 10 ? "%.1f MP" : "%.0f MP", megapixels)
    }

    /// "16:10" when the ratio reduces small enough to be recognizable,
    /// otherwise a decimal like "2.35:1" — an exact but useless "1234:713"
    /// helps nobody.
    var aspectLabel: String? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let divisor = Self.greatestCommonDivisor(pixelWidth, pixelHeight)
        let width = pixelWidth / divisor
        let height = pixelHeight / divisor
        // 2560×1600 reduces to 8:5, but every display on earth is sold as 16:10.
        if width == 8, height == 5 { return "16:10" }
        if width <= 32, height <= 32 { return "\(width):\(height)" }
        return String(format: "%.2f:1", Double(pixelWidth) / Double(pixelHeight))
    }

    /// "@2x" when the file's DPI says it came off a Retina display.
    var scaleLabel: String? {
        guard dpi > 0 else { return nil }
        let scale = Double(dpi) / 72
        guard scale >= 1.5 else { return nil }
        return String(format: scale.rounded() == scale ? "@%.0fx" : "@%.1fx", scale)
    }

    var colorLabel: String? {
        let depth = bitsPerComponent > 0 ? "\(bitsPerComponent)-bit" : nil
        return [colorProfile, depth].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    var fileName: String? {
        path.map { ($0 as NSString).lastPathComponent }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH.mm.ss"
        return formatter.string(from: capturedAt)
    }

    /// Magic bytes only. Pear writes PNGs; JPEG is here for pasted or edited
    /// data, and anything else stays honest rather than guessing.
    static func format(sniffing data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
        return "Image"
    }

    static func from(imageData: Data, fileURL: URL?, now: Date = Date()) -> ScreenshotDetails {
        var width = 0
        var height = 0
        var profile: String?
        var depth = 0
        var alpha = false
        var dpi = 0
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            profile = properties[kCGImagePropertyProfileName] as? String
            depth = properties[kCGImagePropertyDepth] as? Int ?? 0
            alpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
            dpi = (properties[kCGImagePropertyDPIWidth] as? Double).map { Int($0.rounded()) } ?? 0
        }
        return ScreenshotDetails(
            pixelWidth: width,
            pixelHeight: height,
            byteCount: imageData.count,
            format: format(sniffing: imageData),
            capturedAt: now,
            path: fileURL?.path,
            colorProfile: profile,
            bitsPerComponent: depth,
            hasAlpha: alpha,
            dpi: dpi
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Palette by downscale: shrink the image to `count`×1 pixels and read them
/// back. The resample averages for us, so there's no clustering step — the
/// swatches are the shot's horizontal color bands, which is what a screenshot
/// palette wants. Swatches are `PickedColor`s, the same type the eyedropper
/// tool produces, so they copy in the user's chosen HEX/RGB/HSL format.
/// ponytail: no k-means; add one only if the bands read wrong on real shots.
enum DominantColors {
    static func palette(from data: Data, count: Int = 6) -> [PickedColor] {
        guard let thumbnail = Thumbnail.image(from: data, maxPixel: 64),
              let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return palette(from: cgImage, count: count)
    }

    static func palette(from cgImage: CGImage, count: Int = 6) -> [PickedColor] {
        guard count > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: count, height: 1, bitsPerComponent: 8,
                bytesPerRow: count * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: count, height: 1))
            return true
        }
        guard drew else { return [] }
        return (0..<count).map { index in
            let offset = index * 4
            let alpha = Double(pixels[offset + 3]) / 255
            // Undo premultiplication so a transparent cutout doesn't read black.
            let channel: (UInt8) -> Double = { raw in
                alpha > 0 ? min(1, Double(raw) / 255 / alpha) : 0
            }
            return PickedColor(
                red: channel(pixels[offset]),
                green: channel(pixels[offset + 1]),
                blue: channel(pixels[offset + 2])
            )
        }
    }
}

/// Reads one exact pixel out of a capture — the detail view's eyedropper. Pure
/// and testable: point in image pixel space (origin top-left), color out.
enum PixelSampler {
    static func color(in cgImage: CGImage, atX x: Int, y: Int) -> PickedColor? {
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drew = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Shift the image so the wanted pixel lands in the 1×1 context.
            context.draw(cgImage,
                         in: CGRect(x: -x, y: y - cgImage.height + 1,
                                    width: cgImage.width, height: cgImage.height))
            return true
        }
        guard drew else { return nil }
        let alpha = Double(pixel[3]) / 255
        guard alpha > 0 else { return PickedColor(red: 0, green: 0, blue: 0) }
        return PickedColor(
            red: min(1, Double(pixel[0]) / 255 / alpha),
            green: min(1, Double(pixel[1]) / 255 / alpha),
            blue: min(1, Double(pixel[2]) / 255 / alpha)
        )
    }
}

/// Results of the one off-main pass, kept Sendable so it can cross back.
private struct ScreenshotScanResult: Sendable {
    let text: String
    let payloads: [String]
    let colors: [PickedColor]
}

/// Everything Pear knows about a capture beyond its pixels — recognized text,
/// QR payloads, a palette, and file facts. One per preview card; the detail
/// window just reads it, so opening the window shows results already in hand.
@MainActor
@Observable
final class ScreenshotInsights {
    let details: ScreenshotDetails
    private(set) var text = ""
    private(set) var payloads: [String] = []
    private(set) var colors: [PickedColor] = []
    private(set) var isScanning = false

    @ObservationIgnored private let imageData: Data
    @ObservationIgnored private var didStartScan = false

    init(imageData: Data, fileURL: URL?) {
        self.imageData = imageData
        self.details = ScreenshotDetails.from(imageData: imageData, fileURL: fileURL)
    }

    var showsQRBadge: Bool { !payloads.isEmpty }

    /// One idempotent off-main pass: OCR, barcode detect, palette. The preview
    /// controller calls this AFTER the card is on screen, so scanning can never
    /// delay the capture → preview hop.
    func scan() {
        guard !didStartScan else { return }
        didStartScan = true
        isScanning = true
        let data = imageData
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                ScreenshotScanResult(
                    text: OCRText.recognize(inImageData: data),
                    payloads: QRCode.payloads(inImageData: data),
                    colors: DominantColors.palette(from: data)
                )
            }.value
            self.text = result.text
            self.payloads = result.payloads
            self.colors = result.colors
            self.isScanning = false
        }
    }
}
