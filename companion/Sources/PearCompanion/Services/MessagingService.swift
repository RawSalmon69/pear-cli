import Foundation
import Combine

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
/// Concrete services are `ObservableObject`s; `changes` erases their
/// `objectWillChange` so `AppEnvironment` can re-publish it across the
/// existential seam.
@MainActor
protocol MessagingService: AnyObject {
    var messages: [Message] { get }
    var connectionState: ConnectionState { get }
    var changes: AnyPublisher<Void, Never> { get }

    func send(text: String) async throws
    func send(fileAt url: URL, kind: MessageKind) async throws
    func sendPoke() async throws
    func markSeen(_ message: Message) async throws
    func refresh() async
}

@MainActor
final class MockMessagingService: MessagingService, ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var connectionState: ConnectionState

    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

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
