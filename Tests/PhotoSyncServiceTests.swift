import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class PhotoSyncServiceTests: XCTestCase {
    func testQueuesEveryNewMatchingPhotoAndIgnoresOthers() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "simple-1", creationDate: .now), "Simple Camera 5.0.7"),
            (PhotoCandidate(localIdentifier: "other-1", creationDate: .now), "Apple Camera"),
            (PhotoCandidate(localIdentifier: "simple-2", creationDate: .now), "Simple Camera 6.0")
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.queued, 2)
        XCTAssertEqual(uploader.recordedIDs, ["simple-1", "simple-2"])
    }

    func testSecondInvocationDoesNotQueueQueuedAssetsAgain() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "simple-1", creationDate: .now), "Simple Camera 5.0.7")
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

    func testRetriesPhotoWhoseMetadataBecomesAvailableDuringScan() async throws {
        let ledger = try await makeLedger()
        let candidate = PhotoCandidate(
            localIdentifier: "simple-saving",
            creationDate: .now
        )
        let source = EventuallyReadyPhotoSource(candidate: candidate)
        let uploader = RecordingUploader(ledger: ledger)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
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

    func testAutomationWaitsForPhotoThatAppearsAfterInitialScans() async throws {
        let ledger = try await makeLedger()
        let source = DelayedCandidatePhotoSource(availableOnScan: 5)
        let uploader = RecordingUploader(ledger: ledger)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory()
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(source.scanCount, 6)
        XCTAssertEqual(uploader.recordedIDs, ["simple-delayed"])
    }

    func testStopsAfterSuccessfulUploadAndOneQuietScan() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (
                PhotoCandidate(localIdentifier: "simple-fast", creationDate: .now),
                "Simple Camera 5.0.7"
            )
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0, 0, 0]
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(source.scanCount, 2)
    }

    func testFailedUploadIsNotReportedAsCompleted() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (
                PhotoCandidate(localIdentifier: "simple-failed", creationDate: .now),
                "Simple Camera 5.0.7"
            )
        ])
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
            ledger: ledger,
            uploader: FailingUploader(),
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.uploaded, 0)
        XCTAssertEqual(result.failed, 1)
    }

    func testMatchingPhotosBeginUploadingWithoutWaitingForEarlierUploads() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: (1...4).map { index in
            (
                PhotoCandidate(
                    localIdentifier: "simple-\(index)",
                    creationDate: .now
                ),
                "Simple Camera 5.0.7"
            )
        })
        let uploader = BlockingUploader()
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )
        let run = Task {
            try await service.run(trigger: .automation)
        }

        for _ in 0..<100 where uploader.startedCount < 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let startedBeforeRelease = uploader.startedCount
        uploader.releaseAll()
        let result = try await run.value

        XCTAssertEqual(startedBeforeRelease, 4)
        XCTAssertEqual(result.uploaded, 4)
    }

    func testMissingCredentialDoesNotScanOrUpload() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [])
        let uploader = RecordingUploader(ledger: ledger)
        let service = PhotoSyncService(
            credentialStore: InMemoryCredentialStore(),
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
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
            metadataMatcher: TextMetadataMatcher(),
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
    private let items: [(PhotoCandidate, String)]
    private let scanDelayNanoseconds: UInt64
    private var scanCountValue = 0

    init(
        items: [(PhotoCandidate, String)],
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
        return items.map(\.0)
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        let software = items.first { $0.0.localIdentifier == localIdentifier }!.1
        try Data(software.utf8).write(to: destination)
    }
}

private final class EventuallyReadyPhotoSource: PhotoAssetSourcing, @unchecked Sendable {
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
        let software = attempt == 1 ? "metadata pending" : "Simple Camera 5.0.7"
        try Data(software.utf8).write(to: destination)
    }
}

private final class DelayedCandidatePhotoSource: PhotoAssetSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let availableOnScan: Int
    private var scanCountValue = 0

    init(availableOnScan: Int) {
        self.availableOnScan = availableOnScan
    }

    var scanCount: Int { lock.withLock { scanCountValue } }

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        let attempt = lock.withLock { () -> Int in
            scanCountValue += 1
            return scanCountValue
        }
        guard attempt >= availableOnScan else { return [] }
        return [PhotoCandidate(
            localIdentifier: "simple-delayed",
            creationDate: .now
        )]
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        try Data("Simple Camera 5.0.7".utf8).write(to: destination)
    }
}

private struct TextMetadataMatcher: SimpleCameraMetadataMatching {
    func matches(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let value = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }
        return value == "simple camera" || value.hasPrefix("simple camera ")
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

    func upload(assetID: String, fileURL: URL) async throws {
        let taskID = lock.withLock { () -> Int in
            IDs.append(assetID)
            return IDs.count
        }
        try await ledger.markQueued(id: assetID, taskIdentifier: taskID)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class FailingUploader: UploadCoordinating, @unchecked Sendable {
    func upload(assetID: String, fileURL: URL) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class BlockingUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startedCountValue = 0
    private var released = false

    var startedCount: Int { lock.withLock { startedCountValue } }

    func upload(assetID: String, fileURL: URL) async throws {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                startedCountValue += 1
                if released {
                    return true
                }
                continuations.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { continuations.removeAll() }
            return continuations
        }
        pending.forEach { $0.resume() }
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}
