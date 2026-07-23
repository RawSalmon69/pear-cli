import AppKit
import CoreImage
import Vision

/// Pure QR primitives: CoreImage generation and Vision decoding, kept free of
/// UI and capture so both directions are unit-testable headless.
enum QRCode {
    /// Crisp QR image for `string`, or nil when the text is empty or exceeds
    /// QR capacity (CIQRCodeGenerator yields no output then).
    static func generate(from string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Nearest-neighbor upscale keeps module edges sharp for phone cameras.
        let scaled = output.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Payload strings of every barcode/QR Vision finds, de-duplicated in
    /// detection order. Errors read as "nothing found".
    static func decode(in cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var seen = Set<String>()
        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .filter { seen.insert($0).inserted }
    }

    /// Decode straight from encoded image bytes (PNG etc.) — the form the
    /// preview stack holds. Sendable input, so callers can hop executors.
    static func payloads(inImageData data: Data) -> [String] {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return decode(in: cg)
    }

    static func clipboardText(for payloads: [String]) -> String {
        payloads.joined(separator: "\n")
    }

    /// The single-payload http(s) URL, if that's what the code holds — drives
    /// the notification's "Open Link" affordance. Anything else copies as text.
    static func openableURL(in payloads: [String]) -> URL? {
        guard payloads.count == 1,
              let url = URL(string: payloads[0]),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
