import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualTransferJobStoreTests: XCTestCase {
    func testOnlyOneConcurrentRetryClaimIsAcceptedAndFailedPreparationReleasesIt() async throws {
        let root = temporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualTransferJobStore(fileURL: root.appendingPathComponent("queue.json"))
        let entry = ManualTransferHistoryEntry(id: UUID(), fileName: "image.jpg", kind: .photo,
            recipientMailboxID: UUID(), completedAt: Date(), failure: .network,
            assetIdentifier: "original", sha256: nil, recipientCredentialBinding: nil)
        try await store.recordHistory(entry)
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { (try? await store.claimRetry(id: entry.id)) != nil }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        XCTAssertEqual(accepted, 1)
        try await store.finishRetry(id: entry.id, enqueued: false)
        _ = try await store.claimRetry(id: entry.id)
        try await store.finishRetry(id: entry.id, enqueued: true)
        let reopened = ManualTransferJobStore(fileURL: root.appendingPathComponent("queue.json"))
        do {
            _ = try await reopened.claimRetry(id: entry.id)
            XCTFail("The retry marker must survive reopening")
        } catch { XCTAssertEqual(error as? ManualTransferRetryError, .alreadyRetrying) }
    }

    func testOldQueueWithoutHistoryMigratesAndAtomicUpdatesPreserveConcurrentCounts() async throws {
        let root = temporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("queue.json")
        try Data(#"{"batches":[],"jobs":[]}"#.utf8).write(to: url)
        let store = ManualTransferJobStore(fileURL: url)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.history.isEmpty)
        let id = UUID()
        try await store.upsertBatch(.init(id: id, kind: .photo, selectedCount: 100,
            preparedCount: 0, uploadedCount: 0, failedCount: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = try await store.advanceBatch(id: id, preparedBy: 1, failedBy: 1) }
            }
            try await group.waitForAll()
        }
        let persisted = try await ManualTransferJobStore(fileURL: url).load()
        XCTAssertEqual(persisted.batches.first?.preparedCount, 100)
        XCTAssertEqual(persisted.batches.first?.failedCount, 100)
    }

    func testFailedReplacementDoesNotPublishUndurableCachedState() async throws {
        let root = temporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let store = ManualTransferJobStore(fileURL: url)
        try await store.replace(.empty)
        try FileManager.default.removeItem(at: root)
        try Data("blocks directory creation".utf8).write(to: root)
        do {
            try await store.upsertBatch(.init(id: UUID(), kind: .photo, selectedCount: 1,
                preparedCount: 0, uploadedCount: 0, failedCount: 0))
            XCTFail("Replacement must fail without a writable parent directory")
        } catch {}
        let state = try await store.load()
        XCTAssertEqual(state, .empty)
    }

    func testQueueStateRoundTripsWithoutPersistingCredentials() async throws {
        let directory = temporaryDirectory()
        let storeURL = directory.appendingPathComponent("queue.json")
        let batchID = UUID()
        let jobID = UUID()
        let batch = ManualTransferBatch(
            id: batchID,
            kind: .video,
            selectedCount: 2,
            preparedCount: 2,
            uploadedCount: 0,
            failedCount: 1
        )
        let partURL = directory.appendingPathComponent("part-00001.bin")
        let job = ManualTransferJob(
            id: jobID,
            batchID: batchID,
            assetIdentifier: "selected-video",
            kind: .video,
            selectedCount: 2,
            currentIndex: 1,
            exportedFileURL: directory.appendingPathComponent("video.mov"),
            originalFileName: "video.mov",
            contentType: "video/quicktime",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: String(repeating: "a", count: 64),
            remoteID: "123e4567-e89b-42d3-a456-426614174000",
            recipientMailboxID: nil,
            totalBytes: 300_000_000,
            stage: .retrying,
            uploadID: "upload-state-only",
            parts: [
                ManualTransferPart(
                    number: 1,
                    fileURL: partURL,
                    size: 33_554_432,
                    etag: "etag-1",
                    retryAttempt: 2
                )
            ],
            failure: .network
        )
        let expected = ManualTransferQueueState(batches: [batch], jobs: [job])

        let store = ManualTransferJobStore(fileURL: storeURL)
        try await store.replace(expected)
        let reopened = ManualTransferJobStore(fileURL: storeURL)
        let loaded = try await reopened.load()

        XCTAssertEqual(loaded, expected)
        let bytes = try Data(contentsOf: storeURL)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(text.contains("test-secret"))
    }

    func testConsecutiveWritesLeaveValidReplacementJSON() async throws {
        let storeURL = temporaryDirectory().appendingPathComponent("queue.json")
        let store = ManualTransferJobStore(fileURL: storeURL)
        try await store.replace(.init(batches: [], jobs: []))
        let expected = ManualTransferQueueState(
            batches: [
                ManualTransferBatch(
                    id: UUID(),
                    kind: .photo,
                    selectedCount: 1,
                    preparedCount: 1,
                    uploadedCount: 1,
                    failedCount: 0
                )
            ],
            jobs: []
        )

        try await store.replace(expected)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, expected)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualTransferJobStoreTests-(UUID().uuidString)", isDirectory: true)
    }
}
