import Foundation

/// Encrypted-and-stored alongside image/file records: the original filename
/// and byte count. The bytes themselves live in the sealed CKAsset; this is
/// the sealed `ciphertext` payload for `.image` / `.file` messages.
struct FileMetadata: Codable, Equatable, Sendable {
    let filename: String
    let bytes: Int
}
