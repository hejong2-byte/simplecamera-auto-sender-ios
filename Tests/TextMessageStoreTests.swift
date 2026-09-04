import XCTest
@testable import SimpleCameraAutoSender

final class TextMessageStoreTests: XCTestCase {
    func testReceivedMessageSurvivesReopenAndDuplicateIsIdempotent() async throws {
        let root = temporaryRoot()
        let store = TextMessageStore(root: root)
        let message = try envelope(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            text: "  원문\n",
            time: 100
        )
        let body = try message.encoded()

        let firstSave = try await store.saveReceived(message, body: body)
        let duplicateSave = try await store.saveReceived(message, body: body)
        XCTAssertEqual(firstSave, .inserted)
        XCTAssertEqual(duplicateSave, .duplicate)

        let reopened = TextMessageStore(root: root)
        let history = try await reopened.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.envelope.text, "  원문\n")
        XCTAssertEqual(history.first?.status, .received)
        XCTAssertEqual(history.first?.bodySHA256, TextDigest.hex(body))
    }

    func testPendingOutgoingSurvivesReopenAndCanBeMarkedDelivered() async throws {
        let root = temporaryRoot()
        let queued = try await TextMessageStore(root: root).queueOutgoing(
            sender: "123456",
            recipient: "654321",
            text: "전송 대기"
        )
        XCTAssertEqual(queued.status, .pending)

        let reopened = TextMessageStore(root: root)
        let pendingHistory = try await reopened.history()
        XCTAssertEqual(pendingHistory.first?.status, .pending)
        try await reopened.markServerDelivered(id: queued.envelope.id)

        let delivered = try await TextMessageStore(root: root).history()
        XCTAssertEqual(delivered.first?.status, .serverDelivered)
        XCTAssertEqual(delivered.first?.envelope, queued.envelope)
    }

    func testDraftPreservesWhitespaceAndSurvivesReopen() async throws {
        let root = temporaryRoot()
        let draft = TextDraft(recipient: "654321", text: "  앞뒤 공백\n\t")
        let store = TextMessageStore(root: root)

        try await store.saveDraft(draft)

        let reopenedDraft = try await TextMessageStore(root: root).loadDraft()
        XCTAssertEqual(reopenedDraft, draft)
    }

    func testSameIDWithDifferentBodyIsRejectedWithoutReplacingOriginal() async throws {
        let root = temporaryRoot()
        let id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let original = try envelope(id: id, text: "원본", time: 100)
        let collision = try envelope(id: id, text: "변조", time: 101)
        let store = TextMessageStore(root: root)
        let originalBody = try original.encoded()
        _ = try await store.saveReceived(original, body: originalBody)

        do {
            let collisionBody = try collision.encoded()
            _ = try await store.saveReceived(collision, body: collisionBody)
            XCTFail("같은 ID의 다른 본문은 거부해야 합니다.")
        } catch {
            XCTAssertEqual(error as? TextMessageStoreError, .contentCollision)
        }

        let history = try await store.history()
        XCTAssertEqual(history.first?.envelope.text, "원본")
    }

    func testReceivedDeletionWritesTombstoneAndPreventsResurrection() async throws {
        let root = temporaryRoot()
        let message = try envelope(
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            text: "삭제할 수신문",
            time: 100
        )
        let body = try message.encoded()
        let key = TextMessageKey(direction: .received, id: message.id)
        let store = TextMessageStore(root: root)
        _ = try await store.saveReceived(message, body: body)

        try await store.delete(key)

        let afterDeletion = try await store.history()
        XCTAssertTrue(afterDeletion.isEmpty)
        let reopened = TextMessageStore(root: root)
        let saveResult = try await reopened.saveReceived(message, body: body)
        XCTAssertEqual(saveResult, .previouslyDeleted)
        let reopenedHistory = try await reopened.history()
        XCTAssertTrue(reopenedHistory.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("deleted-received.json").path
            )
        )
    }

    func testDeletedTombstoneRejectsSameIDWithDifferentBody() async throws {
        let root = temporaryRoot()
        let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let original = try envelope(id: id, text: "원본", time: 100)
        let replacement = try envelope(id: id, text: "다른 본문", time: 100)
        let store = TextMessageStore(root: root)
        let originalBody = try original.encoded()
        _ = try await store.saveReceived(original, body: originalBody)
        try await store.delete(.init(direction: .received, id: original.id))

        do {
            let replacementBody = try replacement.encoded()
            _ = try await store.saveReceived(replacement, body: replacementBody)
            XCTFail("삭제 표식과 다른 본문은 거부해야 합니다.")
        } catch {
            XCTAssertEqual(error as? TextMessageStoreError, .contentCollision)
        }
    }

    func testHistoryIsNewestFirstAndReadStatePersists() async throws {
        let root = temporaryRoot()
        let older = try envelope(
            id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            text: "이전",
            time: 100
        )
        let newer = try envelope(
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            text: "최신",
            time: 200
        )
        let store = TextMessageStore(root: root)
        let olderBody = try older.encoded()
        let newerBody = try newer.encoded()
        _ = try await store.saveReceived(older, body: olderBody)
        _ = try await store.saveReceived(newer, body: newerBody)
        try await store.markRead(
            .init(direction: .received, id: newer.id),
            at: Date(timeIntervalSince1970: 300)
        )

        let history = try await TextMessageStore(root: root).history()
        XCTAssertEqual(history.map(\.envelope.id), [newer.id, older.id])
        XCTAssertEqual(history.first?.readAt, Date(timeIntervalSince1970: 300))
        XCTAssertNil(history.last?.readAt)
    }

    private func envelope(id: String, text: String, time: TimeInterval) throws -> TextMessageEnvelope {
        try TextMessageEnvelope.make(
            sender: "123456",
            recipient: "654321",
            text: text,
            id: UUID(uuidString: id)!,
            now: Date(timeIntervalSince1970: time)
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMessageStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
