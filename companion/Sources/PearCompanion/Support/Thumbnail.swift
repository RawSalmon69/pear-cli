import AppKit
import ImageIO

/// ImageIO-based downsampling: decodes at thumbnail size instead of
/// inflating the full bitmap, so panel thumbnails of multi-megapixel
/// screenshots stay cheap. `maxPixel` bounds the long side.
enum Thumbnail {
    static func image(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return make(from: source, maxPixel: maxPixel)
    }

    static func image(at url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return make(from: source, maxPixel: maxPixel)
    }

    private static func make(from source: CGImageSource, maxPixel: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
