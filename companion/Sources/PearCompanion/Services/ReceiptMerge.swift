import Foundation

/// A seen-receipt read back from CloudKit. Its own record type because the
/// public database only lets a record's creator modify it — the recipient
/// can't stamp `seenAt` onto the sender's Message, so it writes a Receipt.
struct ReceiptInfo: Equatable, Sendable {
    let messageID: String
    let seenAt: Date
    let byDevice: String
}

/// Folds receipts into messages' `seenAt`, client-side. A receipt only counts
/// when it was written by a device other than the message's sender (i.e. the
/// recipient actually saw it); the latest such receipt wins. Pure and free of
/// CloudKit so it is unit-testable in isolation.
func mergeReceipts(into messages: [Message], receipts: [ReceiptInfo]) -> [Message] {
    messages.map { message in
        var updated = message
        let latest = receipts
            .filter { $0.messageID == message.id.uuidString && $0.byDevice != message.senderDevice }
            .map(\.seenAt)
            .max()
        if let latest {
            updated.seenAt = latest
        }
        return updated
    }
}
