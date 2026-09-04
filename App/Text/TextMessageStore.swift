import Foundation

enum TextMessageDirection: String, Codable, Sendable {
    case sent
    case received
}

enum TextMessageDeliveryStatus: String, Codable, Sendable {
    case pending
    case serverDelivered
    case received
}

struct TextMessageKey: Hashable, Codable, Sendable {
    let direction: TextMessageDirection
    let id: UUID
}

struct TextStoredMessage: Codable, Equatable, Identifiable, Sendable {
    let key: TextMessageKey
    var envelope: TextMessageEnvelope
    let bodySHA256: String
    var status: TextMessageDeliveryStatus
    var readAt: Date?

    var id: TextMessageKey { key }
}

struct TextDraft: Codable, Equatable, Sendable {
    var recipient: String
    var text: String

    static let empty = TextDraft(recipient: "", text: "")
}

enum TextReceiveSaveResult: Equatable, Sendable {
    case inserted
    case duplicate
    case previouslyDeleted
}

enum TextMessageStoreError: Error, Equatable {
    case messageNotFound
    case contentCollision
    case invalidBody
}

actor TextMessageStore {
    private let root: URL
    private let messagesDirectory: URL
    private let draftURL: URL
    private let tombstonesURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        messagesDirectory = root.appendingPathComponent("messages", isDirectory: true)
        draftURL = root.appendingPathComponent("draft.json")
        tombstonesURL = root.appendingPathComponent("deleted-received.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    @discardableResult
    func queueOutgoing(
        sender: String,
        recipient: String,
        text: String
    ) throws -> TextStoredMessage {
        let envelope = try TextMessageEnvelope.make(
            sender: sender,
            recipient: recipient,
            text: text
        )
        let body = try envelope.encoded()
        let message = TextStoredMessage(
            key: TextMessageKey(direction: .sent, id: envelope.id),
            envelope: envelope,
            bodySHA256: TextDigest.hex(body),
            status: .pending,
            readAt: nil
        )
        try persist(message)
        return message
    }

    func markServerDelivered(id: UUID) throws {
        let key = TextMessageKey(direction: .sent, id: id)
        var message = try loadMessage(key)
        message.status = .serverDelivered
        try persist(message)
    }

    @discardableResult
    func saveReceived(
        _ envelope: TextMessageEnvelope,
        body: Data
    ) throws -> TextReceiveSaveResult {
        let decoded: TextMessageEnvelope
        do {
            decoded = try TextMessageEnvelope.decode(
                body,
                expectedRecipient: envelope.recipient
            )
        } catch {
            throw TextMessageStoreError.invalidBody
        }
        guard decoded == envelope else {
            throw TextMessageStoreError.invalidBody
        }

        let id = envelope.id.uuidString.lowercased()
        let bodySHA256 = TextDigest.hex(body)
        let tombstones = try loadTombstones()
        if let deletedSHA256 = tombstones[id] {
            guard deletedSHA256 == bodySHA256 else {
                throw TextMessageStoreError.contentCollision
            }
            return .previouslyDeleted
        }

        let key = TextMessageKey(direction: .received, id: envelope.id)
        let fileURL = messageURL(for: key)
        if fileManager.fileExists(atPath: fileURL.path) {
            let existing = try loadMessage(key)
            guard existing.bodySHA256 == bodySHA256,
                  existing.envelope == envelope else {
                throw TextMessageStoreError.contentCollision
            }
            return .duplicate
        }

        let message = TextStoredMessage(
            key: key,
            envelope: envelope,
            bodySHA256: bodySHA256,
            status: .received,
            readAt: nil
        )
        try persist(message)
        return .inserted
    }

    func history() throws -> [TextStoredMessage] {
        guard fileManager.fileExists(atPath: messagesDirectory.path) else {
            return []
        }
        let tombstones = try loadTombstones()
        let files = try fileManager.contentsOfDirectory(
            at: messagesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try files
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(TextStoredMessage.self, from: Data(contentsOf: $0)) }
            .filter { message in
                message.key.direction != .received
                    || tombstones[message.envelope.id.uuidString.lowercased()] == nil
            }
            .sorted { left, right in
                if left.envelope.createdAt != right.envelope.createdAt {
                    return left.envelope.createdAt > right.envelope.createdAt
                }
                if left.envelope.id != right.envelope.id {
                    return left.envelope.id.uuidString > right.envelope.id.uuidString
                }
                return left.key.direction.rawValue < right.key.direction.rawValue
            }
    }

    func markRead(_ key: TextMessageKey, at date: Date = Date()) throws {
        var message = try loadMessage(key)
        message.readAt = date
        try persist(message)
    }

    func delete(_ key: TextMessageKey) throws {
        let fileURL = messageURL(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw TextMessageStoreError.messageNotFound
        }

        if key.direction == .received {
            let message = try loadMessage(key)
            var tombstones = try loadTombstones()
            tombstones[key.id.uuidString.lowercased()] = message.bodySHA256
            try persist(tombstones, to: tombstonesURL)
        }
        try fileManager.removeItem(at: fileURL)
    }

    func saveDraft(_ draft: TextDraft) throws {
        try persist(draft, to: draftURL)
    }

    func loadDraft() throws -> TextDraft {
        guard fileManager.fileExists(atPath: draftURL.path) else {
            return .empty
        }
        return try decoder.decode(TextDraft.self, from: Data(contentsOf: draftURL))
    }

    private func messageURL(for key: TextMessageKey) -> URL {
        messagesDirectory.appendingPathComponent(
            "\(key.direction.rawValue)-\(key.id.uuidString.lowercased()).json"
        )
    }

    private func loadMessage(_ key: TextMessageKey) throws -> TextStoredMessage {
        let fileURL = messageURL(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw TextMessageStoreError.messageNotFound
        }
        return try decoder.decode(
            TextStoredMessage.self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func persist(_ message: TextStoredMessage) throws {
        try persist(message, to: messageURL(for: message.key))
    }

    private func loadTombstones() throws -> [String: String] {
        guard fileManager.fileExists(atPath: tombstonesURL.path) else {
            return [:]
        }
        return try decoder.decode(
            [String: String].self,
            from: Data(contentsOf: tombstonesURL)
        )
    }

    private func persist<Value: Encodable>(_ value: Value, to fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let replacement = parent.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try encoder.encode(value).write(to: replacement, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: replacement)
            } else {
                try fileManager.moveItem(at: replacement, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: replacement)
            throw error
        }
    }
}
