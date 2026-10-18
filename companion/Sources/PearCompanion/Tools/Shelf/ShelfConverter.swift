import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Convert choices for an image on the shelf.
enum ShelfConversion: CaseIterable, Sendable {
    case png, jpeg, half

    var title: String {
        switch self {
        case .png: return "Convert to PNG"
        case .jpeg: return "Convert to JPEG"
        case .half: return "Resize to 50%"
        }
    }

    /// The choices worth offering for `url`: converting to the format it is
    /// already in is a pointless copy, so that one is left out.
    static func available(for url: URL) -> [ShelfConversion] {
        let type = UTType(filenameExtension: url.pathExtension)
        return allCases.filter {
            switch $0 {
            case .png: return type?.conforms(to: .png) != true
            case .jpeg: return type?.conforms(to: .jpeg) != true
            case .half: return true
            }
        }
    }
}

/// ImageIO conversion of one image file into a new file. Only reads `source`,
/// so the original stays byte-identical. Pure apart from the file it writes,
/// and kept apart from the store so it is testable on its own.
enum ShelfConverter {
    struct Failed: Error {}

    /// Writes the converted image into `directory` and returns its URL.
    /// Named from `stem` (default: the source's own), e.g. `photo.jpg` or
    /// `photo (50%).png`, with a Finder-style suffix rather than overwriting.
    static func convert(_ source: URL, to kind: ShelfConversion, in directory: URL,
                        stem: String? = nil) throws -> URL {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(image),
              CGImageSourceGetCount(image) > 0 else { throw Failed() }
        let stem = stem ?? source.deletingPathExtension().lastPathComponent

        let type: UTType
        let name: String
        switch kind {
        case .png:
            type = .png
            name = "\(stem).png"
        case .jpeg:
            type = .jpeg
            name = "\(stem).jpg"
        case .half:
            // Keep the source format when ImageIO can write it; PNG otherwise
            // (e.g. a camera RAW, which it reads but cannot encode).
            let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            let keep = writable.contains(sourceType as String)
            type = keep ? UTType(sourceType as String) ?? .png : .png
            name = "\(stem) (50%).\(keep ? source.pathExtension : "png")"
        }

        let output = ShelfStore.uniqueDestination(for: directory.appendingPathComponent(name))
        guard let dest = CGImageDestinationCreateWithURL(
            output as CFURL, type.identifier as CFString, 1, nil) else { throw Failed() }
        let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]

        if kind == .half {
            guard let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else { throw Failed() }
            // The thumbnail path downsamples straight from the file and bakes in
            // the EXIF orientation, so the result needs no orientation tag.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, max(width, height) / 2),
            ]
            guard let half = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary)
            else { throw Failed() }
            CGImageDestinationAddImage(dest, half, quality as CFDictionary)
        } else {
            // Copies the pixels with their metadata (orientation included).
            // JPEG has no alpha; ImageIO flattens transparency onto white.
            CGImageDestinationAddImageFromSource(dest, image, 0, quality as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: output)
            throw Failed()
        }
        return output
    }
}
