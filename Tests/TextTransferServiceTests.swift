import XCTest
@testable import SimpleCameraAutoSender

final class TextTransferServiceTests: XCTestCase {
    func testSendPersistsPendingMessageBeforeNetworkAndThenMarksDelivered() async throws {
        let fixture = try makeFixture()
        let client = TextServiceClientProbe(sendObserver: { message, credential in
            let history = try await fixture.store.history()
            XCTAssertEqual(history.first?.key, TextMessageKey(direction: .sent, id: message.id))
            XCTAssertEqual(history.first?.status, .pending)
            XCTAssertEqual(credential, "upload")
        })
        let service = TextTransferService(
            store: fixture.store,
            client: client,
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )

        let result = try await service.send(recipient: "123456", text: "  원문\n")

        XCTAssertEqual(result.envelope.sender, "654321")
        XCTAssertEqual(result.envelope.recipient, "123456")
        XCTAssertEqual(result.status, .serverDelivered)
        let history = try await service.history()
        XCTAssertEqual(history.first?.status, .serverDelivered)
    }

    func testSendFailureLeavesThePersistedRecordPendingForRetry() async throws {
        let fixture = try makeFixture()
        let client = TextServiceClientProbe(sendError: TextProbeError.noReply)
        let service = TextTransferService(
            store: fixture.store,
            client: client,
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.send(recipient: "123456", text: "원문")
        }

        let pending = try await service.history()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.status, .pending)
        await client.clearSendError()
        let retried = try await service.retry(id: try XCTUnwrap(pending.first?.envelope.id))
        XCTAssertEqual(retried.status, .serverDelivered)
    }

    func testReceiveSavesLocallyBeforeACKAndCountsDuplicates() async throws {
        let fixture = try makeFixture()
        let envelope = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "도착 본문",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174111")!
        )
        let body = try envelope.encoded()
        let item = remoteItem(for: body)
        let client = TextServiceClientProbe(
            items: [item],
            bodies: [item.id: body],
            ackObserver: { itemID in
                let history = try await fixture.store.history()
                XCTAssertEqual(history.first?.key.direction, .received)
                XCTAssertEqual(history.first?.envelope.id, envelope.id)
                XCTAssertEqual(itemID, item.id)
            }
        )
        let service = TextTransferService(
            store: fixture.store,
            client: client,
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )

        let first = try await service.receiveOnce()
        let duplicate = try await service.receiveOnce()

        XCTAssertEqual(first, TextReceiveSummary(received: 1, duplicates: 0, rejected: 0, pendingACK: 0))
        XCTAssertEqual(duplicate, TextReceiveSummary(received: 0, duplicates: 1, rejected: 0, pendingACK: 0))
        let acknowledged = await client.acknowledgedIDs()
        XCTAssertEqual(acknowledged, [item.id, item.id])
    }

    func testInvalidOrCollidingIncomingBodiesAreNeverACKed() async throws {
        let fixture = try makeFixture()
        let invalid = Data(#"{"format":"simplecamera-text-v1","id":"123e4567-e89b-42d3-a456-426614174111","sender":"123456","recipient":"111111","created_at":"2026-09-04T01:02:03+00:00","text":"wrong recipient"}"#.utf8)
        let invalidItem = remoteItem(for: invalid)

        let original = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "원본",
            id: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174222")!
        )
        _ = try await fixture.store.saveReceived(original, body: original.encoded())
        let collision = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "다른 본문",
            id: original.id
        ).encoded()
        let collisionItem = remoteItem(for: collision)
        let client = TextServiceClientProbe(
            items: [invalidItem, collisionItem],
            bodies: [invalidItem.id: invalid, collisionItem.id: collision]
        )
        let service = TextTransferService(
            store: fixture.store,
            client: client,
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )

        let summary = try await service.receiveOnce()

        XCTAssertEqual(summary, TextReceiveSummary(received: 0, duplicates: 0, rejected: 2, pendingACK: 0))
        let acknowledged = await client.acknowledgedIDs()
        XCTAssertEqual(acknowledged, [])
    }

    func testACKFailureIsReportedWithoutLosingSavedMessage() async throws {
        let fixture = try makeFixture()
        let body = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "도착 본문"
        ).encoded()
        let item = remoteItem(for: body)
        let client = TextServiceClientProbe(
            items: [item],
            bodies: [item.id: body],
            acknowledgeError: TextProbeError.noReply
        )
        let service = TextTransferService(
            store: fixture.store,
            client: client,
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )

        let summary = try await service.receiveOnce()

        XCTAssertEqual(summary, TextReceiveSummary(received: 1, duplicates: 0, rejected: 0, pendingACK: 1))
        let history = try await service.history()
        XCTAssertEqual(history.first?.key.direction, .received)
    }

    func testDraftReadAndDeleteActionsUseDurableStore() async throws {
        let fixture = try makeFixture()
        let service = TextTransferService(
            store: fixture.store,
            client: TextServiceClientProbe(),
            uploadCredentials: fixture.uploadCredentials,
            registrations: fixture.registrations
        )
        let draft = TextDraft(recipient: "123456", text: "작성 중")
        try await service.saveDraft(draft)
        let loadedDraft = try await service.loadDraft()
        XCTAssertEqual(loadedDraft, draft)

        let message = try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: "읽을 내용"
        )
        _ = try await fixture.store.saveReceived(message, body: message.encoded())
        let key = TextMessageKey(direction: .received, id: message.id)
        try await service.markRead(key)
        let readHistory = try await service.history()
        XCTAssertNotNil(readHistory.first?.readAt)
        try await service.delete(key)
        let deletedHistory = try await service.history()
        XCTAssertEqual(deletedHistory, [])
    }

    private func makeFixture() throws -> TextServiceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextTransferServiceTests-\(UUID().uuidString)", isDirectory: true)
        let store = TextMessageStore(root: root)
        let upload = InMemoryCredentialStore()
        try upload.save("upload")
        let identity = InMemoryCredentialStore()
        let secret = InMemoryCredentialStore()
        let registrations = IPhoneReceiverRegistrationStore(
            identityStore: identity,
            secretStore: secret
        )
        try registrations.save(IPhoneReceiverRegistration(
            receiverID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            code: "654321",
            receiveSecret: "receive",
            deviceName: "희종의 iPhone"
        ))
        return TextServiceFixture(
            store: store,
            uploadCredentials: upload,
            registrations: registrations
        )
    }

    private func remoteItem(for body: Data) -> TextRemoteItem {
        TextRemoteItem(
            id: TextDigest.contentID(body),
            name: "메모.json",
            contentType: TextTransferConstants.mime,
            size: body.count,
            sha256: TextDigest.hex(body),
            createdAt: Date()
        )
    }
}

private struct TextServiceFixture: Sendable {
    let store: TextMessageStore
    let uploadCredentials: InMemoryCredentialStore
    let registrations: IPhoneReceiverRegistrationStore
}

private actor TextServiceClientProbe: TextTransferServing {
    typealias SendObserver = @Sendable (TextMessageEnvelope, String) async throws -> Void
    typealias ACKObserver = @Sendable (UUID) async throws -> Void

    private var sendError: Error?
    private let sendObserver: SendObserver?
    private let items: [TextRemoteItem]
    private let bodies: [UUID: Data]
    private let ackObserver: ACKObserver?
    private let acknowledgeError: Error?
    private var acknowledged: [UUID] = []

    init(
        sendError: Error? = nil,
        sendObserver: SendObserver? = nil,
        items: [TextRemoteItem] = [],
        bodies: [UUID: Data] = [:],
        ackObserver: ACKObserver? = nil,
        acknowledgeError: Error? = nil
    ) {
        self.sendError = sendError
        self.sendObserver = sendObserver
        self.items = items
        self.bodies = bodies
        self.ackObserver = ackObserver
        self.acknowledgeError = acknowledgeError
    }

    func send(_ message: TextMessageEnvelope, uploadCredential: String) async throws {
        if let sendError { throw sendError }
        try await sendObserver?(message, uploadCredential)
    }

    func list(receiverID: UUID, receiveSecret: String) async throws -> [TextRemoteItem] {
        items
    }

    func download(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws -> Data {
        guard let body = bodies[itemID] else { throw TextProbeError.noReply }
        return body
    }

    func acknowledge(receiverID: UUID, itemID: UUID, receiveSecret: String) async throws {
        if let acknowledgeError { throw acknowledgeError }
        try await ackObserver?(itemID)
        acknowledged.append(itemID)
    }

    func clearSendError() { sendError = nil }
    func acknowledgedIDs() -> [UUID] { acknowledged }
}
