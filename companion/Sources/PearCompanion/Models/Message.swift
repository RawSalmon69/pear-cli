import Foundation

enum MessageKind: String, Codable, Sendable {
    case text
    case image
    case poke
    case file
}

/// One item in the couple's shared pipe. Text, images, pokes, and Shelf
/// files are all Messages — only `kind` differs.
struct Message: Identifiable, Equatable, Sendable {
    let id: UUID
    let senderDevice: String
    let sentAt: Date
    let kind: MessageKind

    /// Decrypted text (text messages) or original filename (file/image).
    var text: String?
    /// Local URL of the decrypted asset, if any (image/file).
    var assetURL: URL?
    var seenAt: Date?
}
