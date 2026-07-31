import Foundation

/// Decimal (1000-based) byte formatting, Finder/diskutil style: "512 B",
/// "1.5 kB", "1.0 GB". Every size the disk and monitor views print goes
/// through here, so the format is one testable place.
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
