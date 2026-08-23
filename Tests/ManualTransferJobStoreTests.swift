import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualTransferJobStoreTests: XCTestCase {
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
