import Foundation

/// Transport for the couple's pipe. CloudKit implementation lands in the
/// messaging pass; the mock keeps UI work unblocked.
@MainActor
protocol MessagingService: AnyObject {
    var messages: [Message] { get }
    func send(text: String) async throws
    func send(fileAt url: URL, kind: MessageKind) async throws
    func sendPoke() async throws
    func markSeen(_ message: Message) async throws
    func refresh() async
}

@MainActor
final class MockMessagingService: MessagingService {
    private(set) var messages: [Message] = []

    func send(text: String) async throws {
        messages.append(
            Message(
                id: UUID(),
                senderDevice: "this-mac",
                sentAt: Date(),
                kind: .text,
                text: text
            )
        )
    }

    func send(fileAt url: URL, kind: MessageKind) async throws {
        messages.append(
            Message(
                id: UUID(),
                senderDevice: "this-mac",
                sentAt: Date(),
                kind: kind,
                text: url.lastPathComponent,
                assetURL: url
            )
        )
    }

    func sendPoke() async throws {
        messages.append(
            Message(id: UUID(), senderDevice: "this-mac", sentAt: Date(), kind: .poke)
        )
    }

    func markSeen(_ message: Message) async throws {}
    func refresh() async {}
}
