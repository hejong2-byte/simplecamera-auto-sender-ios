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

        XCTAssertEqual(result.uploaded, 2)
        XCTAssertEqual(Set(uploader.recordedIDs), Set(["simple-1", "simple-2"]))
    }

    func testSecondInvocationDoesNotUploadCompletedAssetsAgain() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "simple-1", creationDate: .now), "Simple Camera 5.0.7")
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        _ = try await service.run(trigger: .automation)
        let second = try await service.run(trigger: .automation)

        XCTAssertEqual(second.uploaded, 0)
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

        XCTAssertEqual(result.uploaded, 1)
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

        XCTAssertEqual(result.uploaded, 1)
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

        XCTAssertEqual(result.uploaded, 1)
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

    func testRepeatedScansCountOneFailedPhotoOncePerRun() async throws {
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
            scanDelaysNanoseconds: [0, 0, 0]
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.uploaded, 0)
        XCTAssertEqual(result.failed, 1)
    }

    func testLaterSuccessClearsEarlierFailureForSamePhoto() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (
                PhotoCandidate(localIdentifier: "simple-eventual", creationDate: .now),
                "Simple Camera 5.0.7"
            )
        ])
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let uploader = FailOnceUploader(ledger: ledger)
        let progressStore = AutomaticTransferProgressStore()
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: TextMetadataMatcher(),
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0, 0],
            automaticProgressStore: progressStore
        )

        let result = try await service.run(trigger: .automation)
        var progressIterator = progressStore.updates().makeAsyncIterator()
        let progress = await progressIterator.next()

        XCTAssertEqual(uploader.attemptCount, 2)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.uploaded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(progress?.totalCount, 1)
        XCTAssertEqual(progress?.uploadedCount, 1)
        XCTAssertEqual(progress?.failedCount, 0)
        XCTAssertEqual(progress?.percent, 100)
    }

    func testServerFailureIsReportedAsServerError() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (
                PhotoCandidate(localIdentifier: "simple-server-failed", creationDate: .now),
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
            uploader: ServerFailingUploader(),
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )

        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.failureCategories, [.server])
        XCTAssertEqual(result.failureDescription, "서버 오류")
        XCTAssertEqual(
            result.automationResultDescription,
            "0장 완료, 1장 재시도 대기 (서버 오류)"
        )
    }

    func testMatchingPhotosUploadOneAtATimeInCreationDateOrder() async throws {
        let ledger = try await makeLedger()
        let origin = Date(timeIntervalSince1970: 1_000)
        let source = FakePhotoSource(items: [3, 1, 4, 2].map { index in
            (PhotoCandidate(
                localIdentifier: "simple-\(index)",
                creationDate: origin.addingTimeInterval(Double(index))
            ), "Simple Camera 5.0.7")
        })
        let uploader = TrackingUploader()
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
        let result = try await service.run(trigger: .automation)

        XCTAssertEqual(result.uploaded, 4)
        XCTAssertEqual(
            uploader.uploadedIDs,
            ["simple-1", "simple-2", "simple-3", "simple-4"]
        )
        XCTAssertEqual(uploader.maximumActiveUploadCount, 1)
    }

    func testAutomaticProgressUsesAggregateActualBytesUntilCompletion() async throws {
        let ledger = try await makeLedger()
        let source = FixedSizePhotoSource(fileBytes: 10, count: 2)
        let uploader = ProgressReportingUploader()
        let progressStore = AutomaticTransferProgressStore()
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials,
            photoSource: source,
            metadataMatcher: AlwaysMatchingMetadataMatcher(),
            ledger: ledger,
            uploader: uploader,
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0],
            automaticProgressStore: progressStore
        )
        let updates = progressStore.updates()
        let collector = Task {
            var values: [AutomaticTransferProgress] = []
            for await value in updates {
                values.append(value)
                if value.stage == .completed || value.stage == .failed {
                    return values
                }
            }
            return values
        }

        let result = try await service.run(trigger: .automation)
        let values = await collector.value

        XCTAssertEqual(result.uploaded, 2)
        XCTAssertTrue(values.contains {
            $0.stage == .uploading && $0.percent == 25
        })
        XCTAssertEqual(values.last?.stage, .completed)
        XCTAssertEqual(values.last?.percent, 100)
        XCTAssertEqual(values.last?.uploadedCount, 2)
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

    func testEmptyRunSaysThereAreNoNewEligiblePhotos() {
        let summary = SyncTransferSummary(
            discovered: 11, matched: 0, uploaded: 0, failed: 0
        )
        XCTAssertEqual(
            summary.automationResultDescription,
            "전송할 새 Simple Cam 사진이 없습니다."
        )
    }

    func testEarlyExitDoesNotLeaveRejectedPhotosForEveryLaterRun() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "simple", creationDate: .now), "Simple Camera")
        ] + (1...11).map {
            (PhotoCandidate(localIdentifier: "other-\($0)", creationDate: .now), "Apple Camera")
        })
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let uploader = RecordingUploader(ledger: ledger)
        let service = PhotoSyncService(
            credentialStore: credentials, photoSource: source,
            metadataMatcher: TextMetadataMatcher(), ledger: ledger,
            uploader: uploader, uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0, 0]
        )

        let first = try await service.run(trigger: .automation)
        let rejectedRecords = await ledger.allRecords().filter {
            $0.id.hasPrefix("other-")
        }
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(rejectedRecords.filter { $0.state == .ignored }.count, 11)

        let exportsBeforeSecondRun = source.exportCount
        let second = try await service.run(trigger: .automation)
        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(source.exportCount, exportsBeforeSecondRun)
        XCTAssertEqual(uploader.recordedIDs, ["simple"])
    }

    func testQueuedPhotoFromTerminatedRunIsRetried() async throws {
        let ledgerURL = temporaryDirectory().appendingPathComponent("ledger.json")
        let previousLedger = try UploadLedger(fileURL: ledgerURL)
        try await previousLedger.setBaseline(Date(timeIntervalSince1970: 0))
        try await previousLedger.recordDiscovery(id: "interrupted", createdAt: .now)
        try await previousLedger.markQueued(id: "interrupted", taskIdentifier: nil)
        let ledger = try UploadLedger(fileURL: ledgerURL)
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "interrupted", creationDate: .now), "Simple Camera")
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        let summary = try await service.run(trigger: .automation)
        let record = try await ledger.record(id: "interrupted")

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(record?.state, .uploaded)
        XCTAssertEqual(uploader.recordedIDs, ["interrupted"])
    }

    func testRetryDoesNotDiscoverUnrelatedNewPhotos() async throws {
        let ledger = try await makeLedger()
        try await ledger.recordDiscovery(id: "retry", createdAt: .now)
        try await ledger.markFailed(id: "retry", category: .network)
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "retry", creationDate: .now), "Simple Camera"),
            (PhotoCandidate(localIdentifier: "new", creationDate: .now), "Simple Camera")
        ])
        let uploader = RecordingUploader(ledger: ledger)
        let service = makeService(ledger: ledger, source: source, uploader: uploader)

        let summary = try await service.run(trigger: .retry)
        let unrelatedRecord = try await ledger.record(id: "new")

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(uploader.recordedIDs, ["retry"])
        XCTAssertNil(unrelatedRecord)
    }

    func testPendingOriginalIsNotAbandonedAfterAnotherPhotoSucceeds() async throws {
        let ledger = try await makeLedger()
        let source = MixedReadinessPhotoSource()
        let uploader = RecordingUploader(ledger: ledger)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let service = PhotoSyncService(
            credentialStore: credentials, photoSource: source,
            metadataMatcher: TextMetadataMatcher(), ledger: ledger,
            uploader: uploader, uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0, 0, 0]
        )

        let summary = try await service.run(trigger: .automation)

        XCTAssertEqual(summary.uploaded, 2)
        XCTAssertEqual(Set(uploader.recordedIDs), ["ready", "pending"])
        XCTAssertEqual(summary.failed, 0)
    }

    func testUnreadableMetadataRemainsRetryableInsteadOfBeingIgnored() async throws {
        let ledger = try await makeLedger()
        let source = FakePhotoSource(items: [
            (PhotoCandidate(localIdentifier: "unreadable", creationDate: .now), "not an image")
        ])
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let uploader = RecordingUploader(ledger: ledger)
        let service = PhotoSyncService(
            credentialStore: credentials, photoSource: source,
            metadataMatcher: SimpleCameraMetadataMatcher(), ledger: ledger,
            uploader: uploader, uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0]
        )

        let summary = try await service.run(trigger: .automation)
        let record = try await ledger.record(id: "unreadable")

        XCTAssertEqual(summary.uploaded, 0)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.lastError, .unreadable)
        XCTAssertTrue(uploader.recordedIDs.isEmpty)
    }

    func testLaterScanErrorKeepsAlreadyConfirmedUploadCount() async throws {
        let ledger = try await makeLedger()
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let progressStore = AutomaticTransferProgressStore()
        let service = PhotoSyncService(
            credentialStore: credentials, photoSource: FailingRescanPhotoSource(),
            metadataMatcher: TextMetadataMatcher(), ledger: ledger,
            uploader: RecordingUploader(ledger: ledger),
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0, 0],
            automaticProgressStore: progressStore
        )

        do {
            _ = try await service.run(trigger: .automation)
            XCTFail("The second scan must fail.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        var iterator = progressStore.updates().makeAsyncIterator()
        let progress = await iterator.next()
        let record = try await ledger.record(id: "confirmed")

        XCTAssertEqual(record?.state, .uploaded)
        XCTAssertEqual(progress?.uploadedCount, 1)
        XCTAssertEqual(progress?.failedCount, 0)
        XCTAssertEqual(progress?.totalCount, 1)
        XCTAssertEqual(progress?.failureCategories, [.network])
    }

    func testCancelledExportDoesNotBecomeFailedPhoto() async throws {
        let ledger = try await makeLedger()
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let progressStore = AutomaticTransferProgressStore()
        let service = PhotoSyncService(
            credentialStore: credentials, photoSource: CancelledExportPhotoSource(),
            metadataMatcher: TextMetadataMatcher(), ledger: ledger,
            uploader: RecordingUploader(ledger: ledger),
            uploadsDirectory: temporaryDirectory(),
            scanDelaysNanoseconds: [0],
            automaticProgressStore: progressStore
        )

        do {
            _ = try await service.run(trigger: .automation)
            XCTFail("Cancellation must interrupt the run.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let record = try await ledger.record(id: "cancelled")
        var iterator = progressStore.updates().makeAsyncIterator()
        let progress = await iterator.next()

        XCTAssertEqual(record?.state, .discovered)
        XCTAssertEqual(progress?.failedCount, 0)
        XCTAssertEqual(progress?.failureCategories, [])
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
    private var exportCountValue = 0

    init(
        items: [(PhotoCandidate, String)],
        scanDelayNanoseconds: UInt64 = 0
    ) {
        self.items = items
        self.scanDelayNanoseconds = scanDelayNanoseconds
    }

    var scanCount: Int { lock.withLock { scanCountValue } }
    var exportCount: Int { lock.withLock { exportCountValue } }

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        lock.withLock { scanCountValue += 1 }
        if scanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: scanDelayNanoseconds)
        }
        return items.map(\.0)
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        lock.withLock { exportCountValue += 1 }
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

private final class FixedSizePhotoSource: PhotoAssetSourcing, @unchecked Sendable {
    private let fileBytes: Int
    private let items: [PhotoCandidate]

    init(fileBytes: Int, count: Int) {
        self.fileBytes = fileBytes
        self.items = (1...count).map { index in
            PhotoCandidate(
                localIdentifier: "fixed-\(index)",
                creationDate: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        items
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        try Data(repeating: 1, count: fileBytes).write(to: destination)
    }
}

private struct AlwaysMatchingMetadataMatcher: SimpleCameraMetadataMatching {
    func matches(fileURL: URL) -> Bool { true }
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

    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let taskID = lock.withLock { () -> Int in
            IDs.append(assetID)
            return IDs.count
        }
        try await ledger.markQueued(id: assetID, taskIdentifier: taskID)
        try await ledger.markUploaded(id: assetID)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class FailingUploader: UploadCoordinating, @unchecked Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class ServerFailingUploader: UploadCoordinating, @unchecked Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        throw UploadHTTPError.server(statusCode: 503)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class FailOnceUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: UploadLedger
    private var attempts = 0

    init(ledger: UploadLedger) {
        self.ledger = ledger
    }

    var attemptCount: Int { lock.withLock { attempts } }

    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            throw URLError(.networkConnectionLost)
        }
        try await ledger.markQueued(id: assetID, taskIdentifier: attempt)
        try await ledger.markUploaded(id: assetID)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class TrackingUploader: UploadCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var activeUploadCount = 0
    private var maximumActiveUploadCountValue = 0
    private var uploadedIDsValue: [String] = []

    var maximumActiveUploadCount: Int {
        lock.withLock { maximumActiveUploadCountValue }
    }

    var uploadedIDs: [String] { lock.withLock { uploadedIDsValue } }

    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        lock.withLock {
            activeUploadCount += 1
            maximumActiveUploadCountValue = max(
                maximumActiveUploadCountValue,
                activeUploadCount
            )
            uploadedIDsValue.append(assetID)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        lock.withLock { activeUploadCount -= 1 }
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private final class ProgressReportingUploader: UploadCoordinating, @unchecked Sendable {
    func upload(
        assetID: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        onProgress(5, 10)
        await Task.yield()
        onProgress(10, 10)
    }

    func authenticationBlocked() -> Bool { false }
    func credentialDidChange() {}
}

private actor MixedReadinessPhotoSource: PhotoAssetSourcing {
    private var pendingExportCount = 0

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        ["ready", "pending"].map {
            PhotoCandidate(localIdentifier: $0, creationDate: .now)
        }
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        if localIdentifier == "pending" {
            pendingExportCount += 1
            if pendingExportCount < 3 {
                throw PhotoAssetSourceError.originalResourceNotFound
            }
        }
        try Data("Simple Camera".utf8).write(to: destination)
    }
}

private actor FailingRescanPhotoSource: PhotoAssetSourcing {
    private var scans = 0

    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        scans += 1
        if scans > 1 { throw URLError(.networkConnectionLost) }
        return [PhotoCandidate(localIdentifier: "confirmed", creationDate: .now)]
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        try Data("Simple Camera".utf8).write(to: destination)
    }
}

private struct CancelledExportPhotoSource: PhotoAssetSourcing {
    func candidates(createdAfter date: Date) async throws -> [PhotoCandidate] {
        [PhotoCandidate(localIdentifier: "cancelled", creationDate: .now)]
    }

    func exportOriginal(localIdentifier: String, to destination: URL) async throws {
        throw URLError(.cancelled)
    }
}
