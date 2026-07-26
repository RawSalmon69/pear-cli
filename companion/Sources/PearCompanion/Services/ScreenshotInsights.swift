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

    var dimensionsLabel: String { "\(pixelWidth) × \(pixelHeight)" }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
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
        if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return ScreenshotDetails(
            pixelWidth: width,
            pixelHeight: height,
            byteCount: imageData.count,
            format: format(sniffing: imageData),
            capturedAt: now,
            path: fileURL?.path
        )
    }
}

/// One swatch of the detail view's palette. Sendable so the palette can be
/// computed off the main actor and handed back whole.
struct PaletteColor: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var hex: String {
        String(format: "#%02X%02X%02X",
               Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// Palette by downscale: shrink the image to `count`×1 pixels and read them
/// back. The resample averages for us, so there's no clustering step — the
/// swatches are the shot's horizontal color bands, which is what a screenshot
/// palette wants.
/// ponytail: no k-means; add one only if the bands read wrong on real shots.
enum DominantColors {
    static func palette(from data: Data, count: Int = 6) -> [PaletteColor] {
        guard let thumbnail = Thumbnail.image(from: data, maxPixel: 64),
              let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return palette(from: cgImage, count: count)
    }

    static func palette(from cgImage: CGImage, count: Int = 6) -> [PaletteColor] {
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
            return PaletteColor(
                red: channel(pixels[offset]),
                green: channel(pixels[offset + 1]),
                blue: channel(pixels[offset + 2])
            )
        }
    }
}

/// Results of the one off-main pass, kept Sendable so it can cross back.
private struct ScreenshotScanResult: Sendable {
    let text: String
    let payloads: [String]
    let colors: [PaletteColor]
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
    private(set) var colors: [PaletteColor] = []
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
