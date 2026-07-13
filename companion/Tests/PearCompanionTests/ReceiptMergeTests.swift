import XCTest
@testable import PearCompanion

final class ReceiptMergeTests: XCTestCase {
    private func message(id: UUID = UUID(), sender: String) -> Message {
        Message(id: id, senderDevice: sender, sentAt: Date(timeIntervalSince1970: 1000), kind: .text, text: "hi")
    }

    func testRecipientReceiptSetsSeenAt() {
        let id = UUID()
        let seen = Date(timeIntervalSince1970: 2000)
        let merged = mergeReceipts(
            into: [message(id: id, sender: "raws")],
            receipts: [ReceiptInfo(messageID: id.uuidString, seenAt: seen, byDevice: "pear")]
        )
        XCTAssertEqual(merged.first?.seenAt, seen)
    }

    func testSenderOwnReceiptIgnored() {
        let id = UUID()
        let merged = mergeReceipts(
            into: [message(id: id, sender: "raws")],
            receipts: [ReceiptInfo(messageID: id.uuidString, seenAt: Date(), byDevice: "raws")]
        )
        XCTAssertNil(merged.first?.seenAt)
    }

    func testUnrelatedReceiptIgnored() {
        let merged = mergeReceipts(
            into: [message(sender: "raws")],
            receipts: [ReceiptInfo(messageID: UUID().uuidString, seenAt: Date(), byDevice: "pear")]
        )
        XCTAssertNil(merged.first?.seenAt)
    }

    func testLatestReceiptWins() {
        let id = UUID()
        let earlier = Date(timeIntervalSince1970: 2000)
        let later = Date(timeIntervalSince1970: 3000)
        let merged = mergeReceipts(
            into: [message(id: id, sender: "raws")],
            receipts: [
                ReceiptInfo(messageID: id.uuidString, seenAt: later, byDevice: "pear"),
                ReceiptInfo(messageID: id.uuidString, seenAt: earlier, byDevice: "pear"),
            ]
        )
        XCTAssertEqual(merged.first?.seenAt, later)
    }

    func testNoReceiptsLeavesMessagesUntouched() {
        let messages = [message(sender: "raws"), message(sender: "pear")]
        XCTAssertEqual(mergeReceipts(into: messages, receipts: []), messages)
    }

    func testMergePreservesOrderAndCount() {
        let a = message(sender: "raws")
        let b = message(sender: "pear")
        let merged = mergeReceipts(into: [a, b], receipts: [])
        XCTAssertEqual(merged.map(\.id), [a.id, b.id])
    }
}
