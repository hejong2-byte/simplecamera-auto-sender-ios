import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class ManualBackgroundTransferEngineTests: XCTestCase {
    func testRetriesSubmitBackgroundDeadlinesForOneThreeAndNineSeconds() async throws {
        let fixture = try await makeFixture(totalBytes: 10, uploadID: nil)
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id, jobID: fixture.job.id, operation: .single
        )
        for (index, delay) in [1.0, 3.0, 9.0].enumerated() {
            let before = Date()
            await engine.taskCompleted(descriptor, response: .status(503), body: Data(), error: nil)
            let after = Date()
            let scheduled = await scheduler.recorded()
            XCTAssertEqual(scheduled.count, index + 1)
            let notBefore = try XCTUnwrap(scheduled.last?.notBefore)
            XCTAssertGreaterThanOrEqual(notBefore, before.addingTimeInterval(delay))
            XCTAssertLessThanOrEqual(notBefore, after.addingTimeInterval(delay))
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.jobs.first?.stage, .retrying)
        }
        await engine.taskCompleted(descriptor, response: .status(503), body: Data(), error: nil)
        let scheduled = await scheduler.recorded()
        XCTAssertEqual(scheduled.count, 3)
        let final = try await fixture.store.load()
        XCTAssertEqual(final.batches.first?.failedCount, 1)
        XCTAssertTrue(final.jobs.isEmpty)
    }

    func testSuspendedRetryDelayDoesNotBlockUnrelatedCompletionOrSystemHandler() async throws {
        let retrying = try await makeFixture(totalBytes: 10, uploadID: nil)
        let successful = try await makeFixture(totalBytes: 10, uploadID: nil)
        try await retrying.store.replace(.init(
            batches: [retrying.batch, successful.batch], jobs: [retrying.job, successful.job]
        ))
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let scheduler = FakeManualUploadScheduler()
        let engine = ManualBackgroundTransferEngine(
            scheduler: scheduler, jobStore: retrying.store,
            credentialStore: credentials
        )
        let registry = BackgroundSessionCompletionRegistry()
        let session = BackgroundManualUploadSession(completionRegistry: registry)
        session.bind(engine: engine)
        let retryRecorded = expectation(description: "retry state is durable")
        let successfulCompletion = expectation(description: "unrelated success was processed")
        let updates = await engine.updates()
        let consumer = Task {
            for await progress in updates {
                if progress.batchID == retrying.batch.id, progress.stage == .retrying {
                    retryRecorded.fulfill()
                }
                if progress.batchID == successful.batch.id, progress.stage == .completed {
                    successfulCompletion.fulfill()
                    break
                }
            }
        }
        defer { consumer.cancel() }
        let failedTask = URLSession.shared.dataTask(with: URL(string: "https://relay.example")!)
        failedTask.taskDescription = try ManualUploadTaskDescriptor(
            batchID: retrying.batch.id, jobID: retrying.job.id, operation: .single
        ).encodedTaskDescription()
        let retryRequestedAt = Date()
        session.urlSession(URLSession.shared, task: failedTask, didCompleteWithError: URLError(.timedOut))
        await fulfillment(of: [retryRecorded], timeout: 5)

        // A described, never-resumed test task supplies an already received HTTP success.
        let completedTask = SuccessfulManualUploadTask()
        completedTask.taskDescription = try ManualUploadTaskDescriptor(
            batchID: successful.batch.id, jobID: successful.job.id, operation: .single
        ).encodedTaskDescription()
        session.urlSession(URLSession.shared, task: completedTask, didCompleteWithError: nil)
        let finished = expectation(description: "system handler excludes future retry delay")
        let drained = expectation(description: "callback cleanup finished")
        registry.store(identifier: AppConfiguration.manualBackgroundSessionIdentifier) {
            finished.fulfill()
            drained.fulfill()
        }
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        await fulfillment(of: [successfulCompletion, finished], timeout: 1)
        let state = try await retrying.store.load()
        XCTAssertEqual(state.batches.first(where: { $0.id == successful.batch.id })?.uploadedCount, 1)
        XCTAssertFalse(state.jobs.contains(where: { $0.id == successful.job.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: successful.job.exportedFileURL.path))
        XCTAssertEqual(state.jobs.first(where: { $0.id == retrying.job.id })?.stage, .retrying)

        await fulfillment(of: [drained], timeout: 5)
        let scheduled = await scheduler.recorded()
        let retry = try XCTUnwrap(scheduled.first(where: { $0.descriptor.jobID == retrying.job.id }))
        let notBefore = try XCTUnwrap(retry.notBefore)
        XCTAssertGreaterThanOrEqual(notBefore, retryRequestedAt.addingTimeInterval(1))
    }

    func testRetryMarkerAndQueuedJobPersistTogether() async throws {
        let original = try await makeFixture(totalBytes: 10, uploadID: nil)
        let engine = makeEngine(fixture: original, scheduler: FakeManualUploadScheduler())
        await engine.taskCompleted(.init(batchID: original.batch.id, jobID: original.job.id, operation: .single),
            response: .status(403), body: Data(), error: nil)
        let retry = try await makeFixture(totalBytes: 10, uploadID: nil)
        var job = retry.job
        job.retryHistoryID = original.job.id
        try await original.store.enqueue([job])
        let reopened = ManualTransferJobStore(fileURL: original.directory.appendingPathComponent("queue.json"))
        let state = try await reopened.load()
        XCTAssertTrue(state.jobs.contains(where: { $0.id == job.id }))
        XCTAssertNotNil(state.history.first(where: { $0.id == original.job.id })?.retriedAt)
        do {
            _ = try await reopened.claimRetry(id: original.job.id)
            XCTFail("A durable queued retry must prevent duplicate retry after restart")
        } catch { XCTAssertEqual(error as? ManualTransferRetryError, .alreadyRetrying) }
    }

    func testFailureHistoryKeepsMostRecent100OutcomesWithoutPruningActiveJob() async throws {
        let active = try await makeFixture(totalBytes: 10, uploadID: nil)
        let engine = makeEngine(fixture: active, scheduler: FakeManualUploadScheduler())
        var failedIDs: [UUID] = []
        for _ in 0..<101 {
            let failed = try await makeFixture(totalBytes: 10, uploadID: nil)
            failedIDs.append(failed.job.id)
            try await engine.enqueue([failed.job])
            await engine.taskCompleted(
                .init(batchID: failed.batch.id, jobID: failed.job.id, operation: .single),
                response: .status(403), body: Data(), error: nil
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: failed.job.exportedFileURL.path))
        }

        let data = try Data(contentsOf: active.directory.appendingPathComponent("queue.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let history = try XCTUnwrap(json["history"] as? [[String: Any]], "Outcomes must survive staging cleanup")
        XCTAssertEqual(history.count, 100)
        XCTAssertEqual(history.first?["id"] as? String, failedIDs.last?.uuidString)
        XCTAssertFalse(history.contains { $0["id"] as? String == failedIDs.first?.uuidString })
        XCTAssertEqual(history.first?["fileName"] as? String, "video.mov")
        XCTAssertEqual(history.first?["assetIdentifier"] as? String, "selected-video")
        XCTAssertNotNil(history.first?["completedAt"])
        XCTAssertNotNil(history.first?["failure"])
        let state = try await active.store.load()
        XCTAssertEqual(state.jobs.map(\.id), [active.job.id])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("test-secret"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"))
    }

    func testSchedulingPreservesInterleavedCompletionPartETagAndEnqueuedJob() async throws {
        let first = try await makeFixture(totalBytes: 10, uploadID: nil)
        let completed = try await makeFixture(totalBytes: 10, uploadID: nil)
        let multipart = try await makeFixture(totalBytes: 10, uploadID: "upload-1", partSizes: [10])
        let added = try await makeFixture(totalBytes: 10, uploadID: nil)
        try await first.store.replace(.init(
            batches: [first.batch, completed.batch, multipart.batch],
            jobs: [first.job, completed.job, multipart.job]
        ))
        let entered = expectation(description: "request construction has read the queue")
        let credentials = PausedManualCredentialStore(entered: entered)
        defer { credentials.release() }
        let pausedEngine = ManualBackgroundTransferEngine(
            scheduler: FakeManualUploadScheduler(), jobStore: first.store,
            credentialStore: credentials
        )
        let restoration = Task { await pausedEngine.restore() }
        await fulfillment(of: [entered], timeout: 5)

        let otherEngine = makeEngine(fixture: first, scheduler: FakeManualUploadScheduler())
        await otherEngine.taskCompleted(
            .init(batchID: completed.batch.id, jobID: completed.job.id, operation: .single),
            response: .success(), body: Data(), error: nil
        )
        await otherEngine.taskCompleted(
            .init(batchID: multipart.batch.id, jobID: multipart.job.id, operation: .part(number: 1)),
            response: .success(), body: Data(#"{"partNumber":1,"etag":"durable-etag"}"#.utf8), error: nil
        )
        try await otherEngine.enqueue([added.job])
        credentials.release()
        await restoration.value

        let state = try await first.store.load()
        XCTAssertEqual(state.batches.first { $0.id == completed.batch.id }?.uploadedCount, 1)
        XCTAssertFalse(state.jobs.contains { $0.id == completed.job.id })
        XCTAssertEqual(state.jobs.first { $0.id == multipart.job.id }?.parts.first?.etag, "durable-etag")
        XCTAssertTrue(state.jobs.contains { $0.id == added.job.id })
    }

    func testFinishEventsWaitsForDeliveredCompletionCleanup() async throws {
        let fixture = try await makeFixture(totalBytes: 10, uploadID: nil)
        let cancellationEntered = expectation(description: "completion reached cancellation")
        let scheduler = PausedManualCancellationScheduler(entered: cancellationEntered)
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test-secret")
        let engine = ManualBackgroundTransferEngine(
            scheduler: scheduler, jobStore: fixture.store, credentialStore: credentials
        )
        let registry = BackgroundSessionCompletionRegistry()
        let session = BackgroundManualUploadSession(completionRegistry: registry)
        session.bind(engine: engine)
        let task = URLSession.shared.dataTask(with: URL(string: "https://relay.example")!)
        task.taskDescription = try ManualUploadTaskDescriptor(
            batchID: fixture.batch.id, jobID: fixture.job.id, operation: .single
        ).encodedTaskDescription()
        session.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.badURL))
        await fulfillment(of: [cancellationEntered], timeout: 5)

        let finished = expectation(description: "system completion")
        let observation = ManualCompletionObservation()
        registry.store(identifier: AppConfiguration.manualBackgroundSessionIdentifier) {
            observation.markFinished()
            finished.fulfill()
        }
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        // This queue barrier runs after an incorrectly immediate main-queue handler.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(observation.finished, "System completion must wait for the delivered event's durable cleanup")
        await scheduler.release()
        await fulfillment(of: [finished], timeout: 5)
        let state = try await fixture.store.load()
        XCTAssertTrue(state.jobs.isEmpty)
        XCTAssertEqual(state.batches.first?.failedCount, 1)
    }

    func testThousandProgressEventsUseLoadedStateWithoutDependingOnQueueFile() async throws {
        let fixture = try await makeFixture(totalBytes: 1_000, uploadID: nil)
        _ = try await fixture.store.load()
        let engine = makeEngine(fixture: fixture, scheduler: FakeManualUploadScheduler())
        let updates = await engine.updates()
        let received = expectation(description: "all cached progress events")
        received.expectedFulfillmentCount = 1_000
        let consumer = Task { () -> ManualTransferProgress? in
            var last: ManualTransferProgress?
            for await progress in updates {
                last = progress
                received.fulfill()
                if progress.taskBytesSent == 1_000 { break }
            }
            return last
        }
        // The store owns the loaded state; progress must not reopen/decode this file.
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("queue.json"))
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id, jobID: fixture.job.id, operation: .single
        )
        for bytes in 1...1_000 {
            await engine.taskProgress(descriptor, sent: Int64(bytes), expected: 1_000)
        }
        await fulfillment(of: [received], timeout: 2)
        consumer.cancel()
        let final = await consumer.value
        XCTAssertEqual(final?.taskBytesSent, 1_000)
        XCTAssertEqual(final?.totalBytes, 1_000)
    }

    func testRestoreMaterializesAndSchedulesOnlyTheFirstMissingPart() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [4, 4, 2]
        )
        for part in fixture.job.parts {
            try FileManager.default.removeItem(at: part.fileURL)
        }
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)

        await engine.restore()

        let scheduled = await scheduler.recorded()
        XCTAssertEqual(scheduled.map(\.descriptor.operation), [.part(number: 1)])
        XCTAssertEqual(try Data(contentsOf: scheduled[0].fileURL), Data(repeating: 1, count: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.job.parts[1].fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.job.parts[2].fileURL.path))
    }

    func testSuccessfulPartDeletesItsTemporaryChunkBeforeSchedulingTheNextPart() async throws {
        let fixture = try await makeFixture(
            totalBytes: 10,
            uploadID: "upload-1",
            partSizes: [4, 6]
        )
        let firstPartURL = fixture.job.parts[0].fileURL
        let scheduler = FakeManualUploadScheduler()
        let engine = makeEngine(fixture: fixture, scheduler: scheduler)
        let descriptor = ManualUploadTaskDescriptor(
            batchID: fixture.batch.id,
            jobID: fixture.job.id,
            operation: .part(number: 1)
        )

        await engine.taskCompleted(
            descriptor,
            response: .success(),
            body: Data(#"{"partNumber":1,"etag":"etag-1"}"#.utf8),
            error: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPartURL.path))
        let scheduled = await scheduler.recorded().map(\.descriptor.operation)
        XCTAssertEqual(scheduled, [.part(number: 2)])
    }

    func testRestoredFileJobsKeepTheirDedicatedRouteOnRetry() async throws {
        let cases: [(Int64, String?, [Int64], Set<Int>, String)] = [
            (10, nil, [], [], "/api/files/"),
            (100_000_000, nil, [], [], "/api/files/multipart"),
            (10, "upload-1", [10], [], "/parts/1"),
            (10, "upload-1", [10], [1], "/complete")
        ]
        for (size, uploadID, parts, completed, path) in cases {
            let fixture = try await makeFixture(totalBytes: size, uploadID: uploadID,
                partSizes: parts, completedPartNumbers: completed, kind: .file)
            let scheduler = FakeManualUploadScheduler()
            let engine = makeEngine(fixture: fixture, scheduler: scheduler)
            await engine.restore()
            let initial = await scheduler.recorded()
            let request = try XCTUnwrap(initial.first)
            XCTAssertTrue(request.request.url?.path.contains(path) == true)
            XCTAssertTrue(request.request.url?.path.hasPrefix("/api/files/") == true)
            await engine.taskCompleted(request.descriptor, response: .status(503), body: Data(), error: nil)
            let retried = await scheduler.recorded()
            XCTAssertEqual(retried.count, 2)
            XCTAssertEqual(retried.last?.request.url, request.request.url)
            if path == "/complete" {
                await engine.taskCompleted(request.descriptor, response: .status(422), body: Data(), error: nil)
                let aborted = await scheduler.recorded()
                XCTAssertEqual(aborted.last?.descriptor.operation, .abort)
                XCTAssertEqual(aborted.last?.request.url?.path, "/api/files/multipart/\(fixture.job.remoteID)")
            }
        }
    }

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
            response: .status(422),
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
            credentialStore: credentials
        )
    }

    private func makeFixture(
        totalBytes: Int64,
        uploadID: String?,
        partSizes: [Int64] = [],
        completedPartNumbers: Set<Int> = [],
        kind: ManualMediaKind = .video
    ) async throws -> EngineFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualEngineTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exported = directory.appendingPathComponent("video.mov")
        try Data(repeating: 1, count: max(1, Int(min(totalBytes, 128)))).write(to: exported)
        let batch = ManualTransferBatch(
            id: UUID(),
            kind: kind,
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
            kind: kind,
            selectedCount: 1,
            currentIndex: 1,
            exportedFileURL: exported,
            originalFileName: "video.mov",
            contentType: "video/quicktime",
            capturedAt: nil,
            sha256: String(repeating: "a", count: 64),
            remoteID: "123e4567-e89b-42d3-a456-426614174000",
            recipientMailboxID: nil,
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

private final class SuccessfulManualUploadTask: URLSessionTask, @unchecked Sendable {
    override var response: URLResponse? { HTTPURLResponse.success() }
}

private final class PausedManualCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var hasPaused = false
    private let gate = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation

    init(entered: XCTestExpectation) { self.entered = entered }
    func save(_ value: String) throws {}
    func clear() throws {}
    func load() throws -> String? {
        let pause = lock.withLock {
            if hasPaused { return false }
            hasPaused = true
            return true
        }
        if pause {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 15) == .success else {
                throw URLError(.timedOut)
            }
        }
        return "Bearer test-secret"
    }
    func release() { gate.signal() }
}

private actor PausedManualCancellationScheduler: ManualUploadTaskScheduling {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }
    func schedule(_ descriptor: ManualUploadTaskDescriptor, request: URLRequest, fileURL: URL, notBefore: Date?) async throws {}
    func existingDescriptors() async -> Set<ManualUploadTaskDescriptor> { [] }
    func cancel(jobID: UUID) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ManualCompletionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var finished: Bool { lock.withLock { value } }
    func markFinished() { lock.withLock { value = true } }
}

private actor FakeManualUploadScheduler: ManualUploadTaskScheduling {
    struct Scheduled: Sendable {
        let descriptor: ManualUploadTaskDescriptor
        let request: URLRequest
        let fileURL: URL
        let notBefore: Date?
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
        fileURL: URL,
        notBefore: Date?
    ) async throws {
        scheduled.append(.init(descriptor: descriptor, request: request, fileURL: fileURL, notBefore: notBefore))
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
        status(200)
    }

    static func status(_ statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://relay.example")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
