import Foundation

struct TextReceiveSummary: Equatable, Sendable {
    let received: Int
    let duplicates: Int
    let rejected: Int
    let pendingACK: Int
}

enum TextTransferServiceError: Error, Equatable {
    case missingRegistration
    case missingUploadCredential
    case messageNotFound
    case messageNotRetryable
    case senderChanged
}

actor TextTransferService {
    private let store: TextMessageStore
    private let client: any TextTransferServing
    private let uploadCredentials: any CredentialStore
    private let registrations: IPhoneReceiverRegistrationStore

    init(
        store: TextMessageStore,
        client: any TextTransferServing,
        uploadCredentials: any CredentialStore,
        registrations: IPhoneReceiverRegistrationStore
    ) {
        self.store = store
        self.client = client
        self.uploadCredentials = uploadCredentials
        self.registrations = registrations
    }

    func send(recipient: String, text: String) async throws -> TextStoredMessage {
        let connection = try requiredConnection()
        let credential = try requiredUploadCredential()
        var message = try await store.queueOutgoing(
            sender: connection.identity.code,
            recipient: recipient,
            text: text
        )
        try await client.send(message.envelope, uploadCredential: credential)
        try await store.markServerDelivered(id: message.envelope.id)
        message.status = .serverDelivered
        return message
    }

    func retry(id: UUID) async throws -> TextStoredMessage {
        let connection = try requiredConnection()
        let credential = try requiredUploadCredential()
        let history = try await store.history()
        guard var message = history.first(where: {
            $0.key.direction == .sent && $0.envelope.id == id
        }) else {
            throw TextTransferServiceError.messageNotFound
        }
        guard message.status == .pending else {
            throw TextTransferServiceError.messageNotRetryable
        }
        guard message.envelope.sender == connection.identity.code else {
            throw TextTransferServiceError.senderChanged
        }
        try await client.send(message.envelope, uploadCredential: credential)
        try await store.markServerDelivered(id: id)
        message.status = .serverDelivered
        return message
    }

    func receiveOnce() async throws -> TextReceiveSummary {
        let connection = try requiredConnection()
        let items = try await client.list(
            receiverID: connection.identity.receiverID,
            receiveSecret: connection.secret
        )
        var received = 0
        var duplicates = 0
        var rejected = 0
        var pendingACK = 0

        for item in items {
            let body: Data
            let envelope: TextMessageEnvelope
            do {
                body = try await client.download(
                    receiverID: connection.identity.receiverID,
                    itemID: item.id,
                    receiveSecret: connection.secret
                )
                guard body.count == item.size,
                      TextDigest.hex(body) == item.sha256,
                      TextDigest.contentID(body) == item.id else {
                    throw TextTransferClientError.invalidRemoteItem
                }
                envelope = try TextMessageEnvelope.decode(
                    body,
                    expectedRecipient: connection.identity.code
                )
            } catch {
                rejected += 1
                continue
            }

            do {
                switch try await store.saveReceived(envelope, body: body) {
                case .inserted:
                    received += 1
                case .duplicate, .previouslyDeleted:
                    duplicates += 1
                }
            } catch {
                rejected += 1
                continue
            }

            do {
                try await client.acknowledge(
                    receiverID: connection.identity.receiverID,
                    itemID: item.id,
                    receiveSecret: connection.secret
                )
            } catch {
                pendingACK += 1
            }
        }

        return TextReceiveSummary(
            received: received,
            duplicates: duplicates,
            rejected: rejected,
            pendingACK: pendingACK
        )
    }

    func history() async throws -> [TextStoredMessage] {
        try await store.history()
    }

    func markRead(_ key: TextMessageKey) async throws {
        try await store.markRead(key)
    }

    func delete(_ key: TextMessageKey) async throws {
        try await store.delete(key)
    }

    func loadDraft() async throws -> TextDraft {
        try await store.loadDraft()
    }

    func saveDraft(_ draft: TextDraft) async throws {
        try await store.saveDraft(draft)
    }

    private func requiredConnection() throws -> IPhoneReceiverCredentials {
        guard let connection = try registrations.load() else {
            throw TextTransferServiceError.missingRegistration
        }
        return connection
    }

    private func requiredUploadCredential() throws -> String {
        guard let credential = try uploadCredentials.load(),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextTransferServiceError.missingUploadCredential
        }
        return credential
    }
}
