import Foundation
import Combine
import CloudKit
import CryptoKit
import UserNotifications
import os

/// Live messaging over the owner's CloudKit public database. Every payload is
/// sealed client-side, so CloudKit only ever holds ciphertext.
///
/// Degrade path is load-bearing: unsigned dev builds have no push entitlement
/// and possibly no iCloud account, so every CloudKit call fails soft — it
/// logs, sets `connectionState`, and returns. A 5-minute foreground poll
/// covers delivery whenever push is unavailable.
@MainActor
final class CloudKitMessagingService: MessagingService, ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var connectionState: ConnectionState = .connecting

    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    private let database: CKDatabase
    private let container: CKContainer
    private let envelope: Envelope
    private let deviceRole: String
    private let logger = Logger(subsystem: CoupleKey.service, category: "cloudkit")

    private let messageRecordType = "Message"
    private let receiptRecordType = "Receipt"
    private let subscriptionID = "pear-message-created"

    private var pollTimer: Timer?
    private var didLoadOnce = false
    private var didRequestNotificationAuth = false
    private var didAttemptSubscription = false
    private var knownMessageIDs: Set<UUID> = []
    private var receiptedIDs: Set<UUID> = []

    private static let shelfExpiry: TimeInterval = 30 * 24 * 60 * 60

    init(key: SymmetricKey, deviceRole: String, containerID: String = "iCloud.com.rawsalmon69.pear") {
        self.container = CKContainer(identifier: containerID)
        self.database = container.publicCloudDatabase
        self.envelope = Envelope(key: key)
        self.deviceRole = deviceRole
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Sending

    func send(text: String) async throws {
        await requestNotificationAuthIfNeeded()
        let sealed = try envelope.seal(Data(text.utf8))
        let record = newMessageRecord(kind: .text, ciphertext: sealed, assetFile: nil)
        await save(record)
        await refresh()
    }

    func sendPoke() async throws {
        await requestNotificationAuthIfNeeded()
        // Poke has no body; seal an empty payload so the record still
        // authenticates as ours on open.
        let sealed = try envelope.seal(Data())
        let record = newMessageRecord(kind: .poke, ciphertext: sealed, assetFile: nil)
        await save(record)
        await refresh()
    }

    func send(fileAt url: URL, kind: MessageKind) async throws {
        await requestNotificationAuthIfNeeded()
        let fileData = try Data(contentsOf: url)
        let metadata = FileMetadata(filename: url.lastPathComponent, bytes: fileData.count)
        let sealedMetadata = try envelope.seal(try JSONEncoder().encode(metadata))
        let sealedBytes = try envelope.seal(fileData)

        let assetFile = try writeTemp(sealedBytes, subdir: "pear-outgoing")
        let record = newMessageRecord(kind: kind, ciphertext: sealedMetadata, assetFile: assetFile)
        await save(record)
        await refresh()
    }

    func markSeen(_ message: Message) async throws {
        // Only the recipient stamps a receipt, and only once.
        guard message.senderDevice != deviceRole,
              message.seenAt == nil,
              !receiptedIDs.contains(message.id) else {
            return
        }
        receiptedIDs.insert(message.id)
        let record = CKRecord(recordType: receiptRecordType)
        record["messageID"] = message.id.uuidString as CKRecordValue
        record["seenAt"] = Date() as CKRecordValue
        record["byDevice"] = deviceRole as CKRecordValue
        await save(record)
    }

    // MARK: - Refresh

    func refresh() async {
        guard await iCloudAvailable() else { return }
        await ensureSubscription()

        do {
            let fetched = try await fetchMessages()
            let receipts = try await fetchReceipts()
            let merged = mergeReceipts(into: fetched, receipts: receipts)
                .sorted { $0.sentAt > $1.sentAt }

            notifyNewIncoming(in: merged)
            knownMessageIDs = Set(merged.map(\.id))
            didLoadOnce = true

            messages = merged
            connectionState = .online
            await expireOwnOldShelfItems()
        } catch {
            logger.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .offline("Sync error")
        }
    }

    // MARK: - CloudKit reads

    private func fetchMessages() async throws -> [Message] {
        let query = CKQuery(recordType: messageRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: false)]
        let (results, _) = try await database.records(matching: query, resultsLimit: 50)
        return results.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return decodeMessage(record)
        }
    }

    private func fetchReceipts() async throws -> [ReceiptInfo] {
        let query = CKQuery(recordType: receiptRecordType, predicate: NSPredicate(value: true))
        let (results, _) = try await database.records(matching: query, resultsLimit: 200)
        return results.compactMap { _, result in
            guard
                let record = try? result.get(),
                let messageID = record["messageID"] as? String,
                let seenAt = record["seenAt"] as? Date,
                let byDevice = record["byDevice"] as? String
            else {
                return nil
            }
            return ReceiptInfo(messageID: messageID, seenAt: seenAt, byDevice: byDevice)
        }
    }

    /// Decrypts a Message record; returns nil for anything that fails to open
    /// (not ours, tampered) or is malformed, so history skips it silently.
    private func decodeMessage(_ record: CKRecord) -> Message? {
        guard
            let kindRaw = record["kind"] as? String,
            let kind = MessageKind(rawValue: kindRaw),
            let sentAt = record["sentAt"] as? Date,
            let senderDevice = record["senderDevice"] as? String,
            let ciphertext = record["ciphertext"] as? Data,
            let plaintext = try? envelope.open(ciphertext)
        else {
            return nil
        }
        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()

        switch kind {
        case .text:
            return Message(id: id, senderDevice: senderDevice, sentAt: sentAt, kind: .text,
                           text: String(data: plaintext, encoding: .utf8))
        case .poke:
            return Message(id: id, senderDevice: senderDevice, sentAt: sentAt, kind: .poke)
        case .image, .file:
            guard let metadata = try? JSONDecoder().decode(FileMetadata.self, from: plaintext) else {
                return nil
            }
            let assetURL = decryptAsset(record["asset"] as? CKAsset, filename: metadata.filename)
            return Message(id: id, senderDevice: senderDevice, sentAt: sentAt, kind: kind,
                           text: metadata.filename, assetURL: assetURL)
        }
    }

    private func decryptAsset(_ asset: CKAsset?, filename: String) -> URL? {
        guard
            let fileURL = asset?.fileURL,
            let sealed = try? Data(contentsOf: fileURL),
            let plaintext = try? envelope.open(sealed)
        else {
            return nil
        }
        let dest = (try? writeTemp(plaintext, subdir: "pear-assets", suffix: "-\(filename)"))
        return dest
    }

    // MARK: - CloudKit writes

    private func newMessageRecord(kind: MessageKind, ciphertext: Data, assetFile: URL?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: UUID().uuidString)
        let record = CKRecord(recordType: messageRecordType, recordID: recordID)
        record["kind"] = kind.rawValue as CKRecordValue
        record["sentAt"] = Date() as CKRecordValue
        record["senderDevice"] = deviceRole as CKRecordValue
        record["ciphertext"] = ciphertext as CKRecordValue
        if let assetFile {
            record["asset"] = CKAsset(fileURL: assetFile)
        }
        return record
    }

    private func save(_ record: CKRecord) async {
        do {
            _ = try await database.save(record)
            connectionState = .online
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .offline("Couldn't reach iCloud")
        }
    }

    /// Opportunistically delete our own expired shelf files (public-DB records
    /// are only deletable by their creator, so each Mac prunes its own).
    private func expireOwnOldShelfItems() async {
        let cutoff = Date().addingTimeInterval(-Self.shelfExpiry)
        let stale = messages.filter {
            $0.kind == .file && $0.senderDevice == deviceRole && $0.sentAt < cutoff
        }
        for message in stale {
            do {
                _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: message.id.uuidString))
            } catch {
                logger.error("shelf expire failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Availability & push

    private func iCloudAvailable() async -> Bool {
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                connectionState = .offline("No iCloud account")
                return false
            }
            return true
        } catch {
            logger.error("accountStatus failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .offline("iCloud unavailable")
            return false
        }
    }

    private func ensureSubscription() async {
        guard !didAttemptSubscription else { return }
        didAttemptSubscription = true

        let subscription = CKQuerySubscription(
            recordType: messageRecordType,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        let log = logger
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            database.save(subscription) { _, error in
                if let error {
                    // Duplicate subscription or missing push entitlement (unsigned
                    // build): fine — the poll covers delivery.
                    log.error("subscription save failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    private func requestNotificationAuthIfNeeded() async {
        guard !didRequestNotificationAuth else { return }
        didRequestNotificationAuth = true
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("notification auth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func notifyNewIncoming(in merged: [Message]) {
        // Skip the first load so we don't fire notifications for existing history.
        guard didLoadOnce else { return }
        let fresh = merged.filter { $0.senderDevice != deviceRole && !knownMessageIDs.contains($0.id) }
        for message in fresh {
            Task { await postLocalNotification(for: message) }
        }
    }

    private func postLocalNotification(for message: Message) async {
        await requestNotificationAuthIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "🍐 Pear"
        switch message.kind {
        case .text: content.body = message.text ?? "sent a note"
        case .image: content.body = "sent a photo"
        case .poke: content.body = "poked you 🍐"
        case .file: content.body = "put \(message.text ?? "a file") on the shelf"
        }
        let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("post notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Task { await refresh() }
    }

    // MARK: - Temp files

    private func writeTemp(_ data: Data, subdir: String, suffix: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + suffix)
        try data.write(to: url)
        return url
    }
}
