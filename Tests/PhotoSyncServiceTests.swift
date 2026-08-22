import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class PhotoSyncServiceTests: XCTestCase {
    func testQueuesEveryNewImageWithoutInspectingMetadata() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            PhotoCandidate(localIdentifier: "camera", creationDate: .now),
            PhotoCandidate(localIdentifier: "simple-cam", creationDate: .now),
            PhotoCandidate(localIdentifier: "screenshot", creationDate: .now)
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        let result = try await service.run(trigger: .manual)

        XCTAssertEqual(result.discovered, 3)
        XCTAssertEqual(result.queued, 3)
        XCTAssertEqual(uploader.recordedIDs, ["camera", "simple-cam", "screenshot"])
    }

    func testQueuesEveryNewPhotoRegardlessOfSource() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            PhotoCandidate(localIdentifier: "simple-1", creationDate: .now),
            PhotoCandidate(localIdentifier: "other-1", creationDate: .now),
            PhotoCandidate(localIdentifier: "simple-2", creationDate: .now)
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.queued, 3)
        XCTAssertEqual(uploader.recordedIDs, ["simple-1", "other-1", "simple-2"])
    }

    func testSecondInvocationDoesNotQueueQueuedAssetsAgain() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            PhotoCandidate(localIdentifier: "simple-1", creationDate: .now)
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        _ = try await service.run(trigger: .automation)
        let second = try await service.run(trigger: .automation)

        XCTAssertEqual(second.queued, 0)
        XCTAssertEqual(uploader.recordedIDs, ["simple-1"])
    }

    func testConcurrentInvocationsCoalesceToOneScan() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [], scanDelayNanoseconds: 100_000_000)
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        async let first = service.run(trigger: .automation)
        async let second = service.run(trigger: .automation)
        _ = try await (first, second)

        XCTAssertEqual(source.scanCount, 1)
    }

    func testRetriesPhotoWhoseOriginalBecomesAvailableDuringScan() async throws {
        let ledger = try await makeLedger()
        let candidate = PhotoCandidate(
            localIdentifier: "simple-saving",
            creationDate: .now
        )
        let source = EventuallyReadablePhotoSource(candidate: candidate)
        let uploader = RecordingUploader(ledger: ledger)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0]
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(source.exportCount, 2)
        XCTAssertEqual(uploader.recordedIDs, ["simple-saving"])
    }

    func testMissingCredentialDoesNotScanOrUpload() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [])
        let uploader = RecordingUploader(ledger: ledger)
        let service = PhotoSyncService(
            credentialStore: InMemoryCredentialStore(),
            photoSource: source,
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )

        do {
            _ = try await service.run(trigger: .automation)
            XCTFail("인증값이 없으면 실패해야 합니다.")
        } catch UploadConfigurationError.missingCredential {
            XCTAssertEqual(source.scanCount, 0)
        }
    }

    private func makeService(
        ledger: UploadLedger,
        source: FakePhotoSource,
        uploader: RecordingUploader
    ) -> PhotoSyncService {
        let credentials = InMemoryCredentialStore()
        try! credentials.save("test-secret")
        return PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )
    }

    private func makeLedger() async throws -> UploadLedger {
        let ledger = try UploadLedger(
            fileURL: temporaryDirectory().appendingPathComponent("ledger.json")
        )
        try await ledger.setBaseline(Date(timeIntervalSince1970: 0))
        return ledger
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class FakePhotoSource: PhotoAssetSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let items: [PhotoCandidate]
    private let scanDelayNanoseconds: UInt64
    private var scanCountValue = 0

    init(
        items: [PhotoCandidate],
        scanDelayNanoseconds: UInt64 = 0
    ) {
        self.items = items
        self.scanDelayNanoseconds = scanDelayNanoseconds
    }

    var scanCount: Int { lock.withLock { scanCountValue } }

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        lock.withLock { scanCountValue += 1 }
        if scanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        return items
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        try Data(localIdentifier.utf8).write(to: destination)
    }
}

private final class EventuallyReadablePhotoSource: PhotoAssetSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let candidate: PhotoCandidate
    private var exportCountValue = 0

    init(candidate: PhotoCandidate) {
        self.candidate = candidate
    }

    var exportCount: Int { lock.withLock { exportCountValue } }

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        [candidate]
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        let attempt = lock.withLock { () -> Int in
            exportCountValue += 1
            return exportCountValue
        }
        if attempt == 1 {
            throw PhotoAssetSourceError.originalResourceNotFound
        }
        try Data(localIdentifier.utf8).write(to: destination)
    }
}

private final class RecordingUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: UploadLedger
    private var IDs: [String] = []

    init(ledger: UploadLedger) {
        self.ledger = ledger
    }

    var recordedIDs: [String] { lock.withLock { IDs } }

    func enqueue(assetID: String, fileURL: URL) async throws {
        let taskID = lock.withLock { () -> Int in
            IDs.append(assetID)
            return IDs.count
        }
        try await ledger.markQueued(id: assetID, taskIdentifier: taskID)
    }

    func reconnect() async {}
    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
