import Foundation
import Observation

/// What the panel shows about the pipe. `.needsSetup` means no couple key is
/// installed yet; `.offline` carries a short human reason (no iCloud account,
/// push unavailable, a failed request) so unsigned/degraded builds still run.
enum ConnectionState: Equatable, Sendable {
    case needsSetup
    case connecting
    case online
    case offline(String)
}

/// Transport for the couple's pipe. CloudKit is the live backend; the mock
/// keeps UI work unblocked and covers the no-iCloud / no-key case.
///
/// Concrete services are `@Observable`, so views reading `messages` or
/// `connectionState` through this existential still get change tracking.
@MainActor
protocol MessagingService: AnyObject {
    var messages: [Message] { get }
    var connectionState: ConnectionState { get }

    func send(text: String) async throws
    func send(fileAt url: URL, kind: MessageKind) async throws
    func sendPoke() async throws
    func markSeen(_ message: Message) async throws
    func refresh() async
}

@MainActor
@Observable
final class MockMessagingService: MessagingService {
    private(set) var messages: [Message] = []
    private(set) var connectionState: ConnectionState

    init(connectionState: ConnectionState = .online) {
        self.connectionState = connectionState
    }

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
