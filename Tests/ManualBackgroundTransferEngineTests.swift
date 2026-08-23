import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualBackgroundTransferEngineTests: XCTestCase {
    func testTaskDescriptorRoundTripsWithoutSecretsOrLocations() throws {
        let descriptor = ManualUploadTaskDescriptor(
            batchID: UUID(),
            jobID: UUID(),
            operation: .part(number: 7)
        )

        let encoded = try descriptor.encodedTaskDescription()
        XCTAssertEqual(try ManualUploadTaskDescriptor(taskDescription: encoded), descriptor)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("uploadid"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("filename"))
        XCTAssertFalse(encoded.contains("https://"))
    }

    func testRestoreSchedulesOnlyARequestMissingFromBackgroundSession() async throws {
        let fixture = try await makeFixture(totalBytes: 100_000_000, uploadID: nil)
        let start = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .start
        )
        let occupied = FakeManualUploadScheduler(existing: [start])
        let occupiedEngine = makeEngine(fixture: fixture, scheduler: occupied)

        await occupiedEngine.restore()
        let occupiedRequests = await occupied.recorded()
        XCTAssertTrue(occupiedRequests.isEmpty)

        let vacant = FakeManualUploadScheduler()
        let vacantEngine = makeEngine(fixture: fixture, scheduler: vacant)
        await vacantEngine.restore()

        let vacantDescriptors = await vacant.recorded().map(\.descriptor)
        XCTAssertEqual(vacantDescriptors, [start])
    }

    func testSuccessfulPartPersistsETagAndSchedulesCompletionExactlyOnce() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [4, 6],
            completedPartNumbers: [1]
        )
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .part(number: 2)
        )
        let response = HTTPURLResponse.success()
        let body = Data(#"{"partNumber":2,"etag":"etag-2"}"#.utf8)

        await engine.taskCompleted(descriptor, response: response, body: body, error: nil)
        await engine.taskCompleted(descriptor, response: response, body: body, error: nil)

        let stored = try await fixture.store.load()
        XCTAssertEqual(stored.jobs.first?.parts.last?.etag, "etag-2")
        let operations = await scheduler.recorded().map(\.descriptor.operation)
        XCTAssertEqual(operations.filter { $0 == .complete }.count, 1)
    }

    func testTemporaryPartFailureRetriesOnlyThatPart() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [4, 6],
            completedPartNumbers: [1]
        )
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let failedPart = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .part(number: 2)
        )

        await engine.taskCompleted(
            failedPart,
            response: nil,
            body: Data(),
            error: URLError(.timedOut)
        )

        let retriedDescriptors = await scheduler.recorded().map(\.descriptor)
        XCTAssertEqual(retriedDescriptors, [failedPart])
        let stored = try await fixture.store.load()
        XCTAssertEqual(stored.jobs.first?.parts.first?.etag, "etag-1")
        XCTAssertEqual(stored.jobs.first?.parts.last?.retryAttempt, 1)
    }

    func testIntegrityFailureIncrementsCountImmediatelyAndSchedulesAbort() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [10]
        )
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .complete
        )

        await engine.taskCompleted(
            descriptor,
            response: .init(statusCode: 422),
            body: Data(#"{"error":"size_mismatch"}"#.utf8),
            error: nil
        )

        let stored = try await fixture.store.load()
        XCTAssertEqual(stored.batches.first?.failedCount, 1)
        XCTAssertEqual(stored.jobs.first?.failure, .server(statusCode: 422, code: "size_mismatch"))
        let scheduledOperations = await scheduler.recorded().map(\.descriptor.operation)
        XCTAssertEqual(scheduledOperations, [.abort])
    }

    func testCanceledBackgroundTaskStaysResumableWithoutAbort() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [10]
        )
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .part(number: 1)
        )

        await engine.taskCompleted(
            descriptor,
            response: nil,
            body: Data(),
            error: URLError(.cancelled)
        )

        let stored = try await fixture.store.load()
        let scheduled = await scheduler.recorded()
        XCTAssertEqual(stored.jobs.count, 1)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testProgressCombinesConfirmedAndActiveTaskBytes() async throws {
        let fixture = try await makeFixture(
            totalBytes: 100,
            uploadID: "upload-1",
            partSizes: [60, 40],
            completedPartNumbers: [1]
        )
        let engine = makeEngine(fixture: fixture, scheduler: FakeManualUploadScheduler())
        var iterator = await engine.updates().makeAsyncIterator()
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .part(number: 2)
        )

        await engine.taskProgress(descriptor, sent: 20, expected: 40)
        let progress = await iterator.next()

        XCTAssertEqual(progress?.confirmedBytes, 60)
        XCTAssertEqual(progress?.taskBytesSent, 20)
        XCTAssertEqual(progress?.percent, 80)
    }

    private func makeEngine(
        fixture: EngineFixture,
        scheduler: FakeManualUploadScheduler
    ) -> ManualBackgroundTransferEngine {
        let credentials = InMemoryCredentialStore()
        try! credentials.save("Bearer test-secret")
        return ManualBackgroundTransferEngine(
            scheduler: scheduler,
            jobStore: fixture.store,
            credentialStore: credentials,
            sleep: { _ in }
        )
    }

    private func makeFixture(
        totalBytes: Int64,
        uploadID: String?,
        partSizes: [Int64] = [],
        completedPartNumbers: Set<Int> = []
    ) async throws -> EngineFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualEngineTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exported = directory.appendingPathComponent("video.mov")
        try Data(repeating: 1, count: max(1, Int(min(totalBytes, 128)))).write(to: exported)
        let batch = ManualTransferBatch(
            id: UUID(),
            kind: .video,
            selectedCount: 1,
            preparedCount: 1,
            uploadedCount: 0,
            failedCount: 0
        )
        var parts: [ManualTransferPart] = []
        for (offset, size) in partSizes.enumerated() {
            let number = offset + 1
            let url = directory.appendingPathComponent(String(format: "part-%05d.bin", number))
            try Data(repeating: UInt8(number), count: Int(size)).write(to: url)
            parts.append(ManualTransferPart(
                number: number,
                fileURL: url,
                size: size,
                etag: completedPartNumbers.contains(number) ? "etag-\(number)" : nil,
                retryAttempt: 0
            ))
        }
        let job = ManualTransferJob(
            id: UUID(),
            batchID: batch.id,
            assetIdentifier: "selected-video",
            kind: .video,
            selectedCount: 1,
            currentIndex: 1,
            exportedFileURL: exported,
            originalFileName: "video.mov",
            contentType: "video/quicktime",
            capturedAt: nil,
            sha256: String(repeating: "a", count: 64),
            remoteID: "123e4567-e89b-42d3-a456-426614174000",
            totalBytes: totalBytes,
            stage: .uploading,
            uploadID: uploadID,
            parts: parts,
            failure: nil
        )
        let store = ManualTransferJobStore(fileURL: directory.appendingPathComponent("queue.json"))
        try await store.replace(.init(batches: [batch], jobs: [job]))
        return EngineFixture(directory: directory, store: store, batch: batch, job: job)
    }
}

private struct EngineFixture {
    let directory: URL
    let store: ManualTransferJobStore
    let batch: ManualTransferBatch
    let job: ManualTransferJob
}

private actor FakeManualUploadScheduler: ManualUploadTaskScheduling {
    struct Scheduled: Sendable {
        let descriptor: ManualUploadTaskDescriptor
        let request: URLRequest
        let fileURL: URL
    }

    private let existing: Set<ManualUploadTaskDescriptor>
    private var scheduled: [Scheduled] = []
    private var canceledJobIDs: [UUID] = []

    init(existing: Set<ManualUploadTaskDescriptor> = []) {
        self.existing = existing
    }

    func schedule(
        _ descriptor: ManualUploadTaskDescriptor,
        request: URLRequest,
        fileURL: URL
    ) async throws {
        scheduled.append(.init(descriptor: descriptor, request: request, fileURL: fileURL))
    }

    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor> {
        existing.union(scheduled.map(\.descriptor))
    }

    func cancel(jobID: UUID) async {
        canceledJobIDs.append(jobID)
    }

    func recorded() -> [Scheduled] {
        scheduled
    }
}

private extension HTTPURLResponse {
    static func success() -> HTTPURLResponse {
        .init(statusCode: 200)
    }

    convenience init(statusCode: Int) {
        self.init(
            url: URL(string: "https://relay.example")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
