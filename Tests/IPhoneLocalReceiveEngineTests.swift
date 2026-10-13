import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

private final class LocalReceiveNotificationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferNotificationEvent] = []
    var values: [TransferNotificationEvent] { lock.withLock { events } }
    func append(_ event: TransferNotificationEvent) { lock.withLock { events.append(event) } }
}

final class IPhoneLocalReceiveEngineTests: XCTestCase {
    func testInitialSchedulingPreservesCompletionDuringLeaseOrScheduleAwait() async throws {
        for pauseAtLease in [true, false] {
            let payload = Data("completed during initial scheduling".utf8)
            let context = try makeContext(payloads: ["initial.txt": payload])
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            let entered = expectation(description: pauseAtLease ? "Initial lease entered" : "Initial schedule entered")
            let gate = LocalReceiveEnumerationGate(entered: entered)
            if pauseAtLease { context.client.setLeaseGate(gate) }
            else { await context.scheduler.setScheduleGate(gate) }
            let discovery = Task { try await context.engine.discoverAndSchedule() }
            await fulfillment(of: [entered], timeout: 2)
            let staging = context.catalog.stagingDirectory.appendingPathComponent("initial.download")
            try payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
            let completed = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
            XCTAssertEqual(completed.stage, .completed)
            await gate.open()
            try await discovery.value

            XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), completed)
            let scheduled = await context.scheduler.scheduledIDs()
            XCTAssertTrue(scheduled.isEmpty, "Initial scheduling must preserve callback advancement across its awaits")
            XCTAssertEqual(context.client.acks().count, 1)
            XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("initial.txt")), payload)
        }
    }

    func testRecoveryPreservesCompletionDuringLeaseOrScheduleAwait() async throws {
        for pauseAtLease in [true, false] {
            let payload = Data("completed during recovery".utf8)
            let context = try makeContext(payloads: ["done.txt": payload])
            try await context.engine.discoverAndSchedule()
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            await context.scheduler.cancel(deliveryID: delivery.deliveryID)
            let entered = expectation(description: pauseAtLease ? "Lease entered" : "Schedule entered")
            let gate = LocalReceiveEnumerationGate(entered: entered)
            if pauseAtLease { context.client.setLeaseGate(gate) }
            else { await context.scheduler.setScheduleGate(gate) }
            let poll = Task { try await context.engine.discoverAndSchedule() }
            await fulfillment(of: [entered], timeout: 2)
            let staging = context.catalog.stagingDirectory.appendingPathComponent("done.download")
            try payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
            let completed = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
            XCTAssertEqual(completed.stage, .completed)
            await gate.open()
            try await poll.value

            XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), completed)
            let scheduled = await context.scheduler.scheduledIDs()
            XCTAssertTrue(scheduled.isEmpty, "Recovery must not retain a task for a delivery completed during its awaited operation")
            XCTAssertEqual(context.client.acks().count, 1)
            XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("done.txt")), payload)
        }
    }

    func testRecoveryDoesNotRescheduleAJobCompletedWhileEnumeratingSystemTasks() async throws {
        let payload = Data("completed during enumeration".utf8)
        let recorder = ReceivedMediaSaveRecorder()
        let context = try makeContext(payloads: ["photo.jpg": payload],
            saveReceivedMedia: { url, type in await recorder.record(url: url, contentType: type); return true })
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        await context.scheduler.cancel(deliveryID: delivery.deliveryID)
        let entered = expectation(description: "System task enumeration entered")
        let gate = LocalReceiveEnumerationGate(entered: entered)
        await context.scheduler.setEnumerationGate(gate)
        let poll = Task { try await context.engine.discoverAndSchedule() }
        await fulfillment(of: [entered], timeout: 2)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("photo.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        let completed = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
        XCTAssertEqual(completed.stage, .completed)
        await gate.open()
        try await poll.value

        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), completed)
        let scheduled = await context.scheduler.scheduledIDs()
        let imports = await recorder.values()
        XCTAssertTrue(scheduled.isEmpty, "Recovery must reread durable state after awaiting system task enumeration")
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("photo.jpg")), payload)
    }

    func testHTTP503DelegateFailureAcceptsExplicitRetry() async throws {
        try await assertHTTPDelegateRetry(status: 503, retryAllowed: true)
    }

    func testHTTP429DelegateFailureAcceptsExplicitRetry() async throws {
        try await assertHTTPDelegateRetry(status: 429, retryAllowed: true)
    }

    func testHTTP404DelegateFailureDoesNotAcceptRetry() async throws {
        try await assertHTTPDelegateRetry(status: 404, retryAllowed: false)
    }

    func testHTTP410DelegateFailureDoesNotAcceptRetry() async throws {
        try await assertHTTPDelegateRetry(status: 410, retryAllowed: false)
    }

    private func assertHTTPDelegateRetry(status: Int, retryAllowed: Bool) async throws {
            let context = try makeContext(payloads: ["retry.txt": Data("retry".utf8)])
            try await context.engine.discoverAndSchedule()
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            await context.scheduler.cancel(deliveryID: delivery.deliveryID)
            let registry = BackgroundSessionCompletionRegistry()
            let background = try BackgroundIPhoneReceiveSession(
                stagingDirectory: context.catalog.stagingDirectory, completionRegistry: registry)
            background.bind(sink: context.engine)
            let handled = expectation(description: "HTTP failure is durable for \(status)")
            registry.store(identifier: AppConfiguration.receiverBackgroundSessionIdentifier) { handled.fulfill() }
            let session = URLSession(configuration: .ephemeral)
            let task = HTTPFailureReceiveDownloadTask()
            task.status = status
            XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, status)
            task.taskDescription = try IPhoneReceiveTaskDescriptor(deliveryID: delivery.deliveryID).encodedTaskDescription()
            let staging = context.catalog.stagingDirectory.appendingPathComponent("http.download")
            try Data("server error".utf8).write(to: staging)
            background.urlSession(session, downloadTask: task, didFinishDownloadingTo: staging)
            background.urlSessionDidFinishEvents(forBackgroundURLSession: session)
            await fulfillment(of: [handled], timeout: 2)
            session.invalidateAndCancel()
            XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .failed)
            if retryAllowed {
                XCTAssertTrue(context.jobs.job(for: delivery.deliveryID)?.lastError?.contains("HTTP \(status)") == true,
                    "The actual delegate must deliver the intended transient HTTP error")
            }
            try await context.engine.discoverAndSchedule()
            let beforeApproval = await context.scheduler.scheduledIDs()
            XCTAssertTrue(beforeApproval.isEmpty, "HTTP failures still require an explicit retry decision")

            try await context.engine.retryFailedDelivery(deliveryID: delivery.deliveryID)

            let scheduled = await context.scheduler.scheduledIDs()
            if retryAllowed {
                XCTAssertEqual(scheduled, [delivery.deliveryID])
                XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .downloading)
            } else {
                XCTAssertTrue(scheduled.isEmpty)
                XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .failed)
            }
            XCTAssertTrue(context.client.acks().isEmpty)
            XCTAssertTrue(try context.catalog.refresh().isEmpty)
    }

    func testLateDownloadCallbacksDoNotDowngradeVerifiedCompletedJob() async throws {
        let payload = Data("verified".utf8)
        let context = try makeContext(payloads: ["verified.txt": payload])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("verified.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        let completed = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
        await context.engine.downloadFailed(deliveryID: delivery.deliveryID, error: URLError(.cancelled))
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), completed)
        let duplicate = context.catalog.stagingDirectory.appendingPathComponent("duplicate.download")
        try payload.write(to: duplicate)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: duplicate)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), completed)
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("verified.txt")), payload)
    }

    func testForegroundPumpDoesNotReenterDeliveredCallbackWhilePhotoImportIsSuspended() async throws {
        let firstEntered = expectation(description: "Photo import entered")
        let secondBoundary = LocalReceiveTestSignal(expectation(description: "Poll returns or duplicate import enters"))
        let gate = LocalReceiveAckGate(firstEntered: firstEntered, secondBoundary: secondBoundary)
        let payload = Data("photo".utf8)
        let context = try makeContext(payloads: ["photo.jpg": payload],
            saveReceivedMedia: { _, _ in await gate.wait(); return true })
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("photo.download")
        try payload.write(to: staging)
        let callback = Task {
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        }
        await fulfillment(of: [firstEntered], timeout: 2)
        let poll = Task {
            try await context.engine.discoverAndSchedule()
            await context.engine.restore()
            secondBoundary.fulfill()
        }
        await fulfillment(of: [secondBoundary.expectation], timeout: 2)
        let importCount = await gate.enteredCount()
        XCTAssertEqual(importCount, 1, "A delivered callback owns finalization while its photo import is suspended")
        await gate.open()
        await callback.value
        try await poll.value
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .completed)
        XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("photo.jpg")), payload)
    }

    func testConcurrentRestoreAndForegroundPollSerializePendingAcknowledgement() async throws {
        let payload = Data("pending ack".utf8)
        let context = try makeContext(payloads: ["ack.txt": payload], ackFailures: 1)
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("ack.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        let firstEntered = expectation(description: "First ACK entered")
        let secondBoundary = LocalReceiveTestSignal(expectation(description: "Second pump reached its boundary"))
        let gate = LocalReceiveAckGate(firstEntered: firstEntered, secondBoundary: secondBoundary)
        context.client.setAcknowledgementGate(gate)
        let first = Task { await context.engine.restore() }
        await fulfillment(of: [firstEntered], timeout: 2)
        let second = Task {
            try await context.engine.discoverAndSchedule()
            await context.engine.restore()
            secondBoundary.fulfill()
        }
        await fulfillment(of: [secondBoundary.expectation], timeout: 2)
        let enteredCount = await gate.enteredCount()
        XCTAssertEqual(enteredCount, 1, "Actor reentrancy must not allow another ACK while the first is awaiting transport")
        await gate.open()
        await first.value
        try await second.value
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .completed)
    }

    func testDelayedProgressCannotResurrectTerminalOrReceiptPendingJobs() async throws {
        for ackFailures in [0, 1] {
            let payload = Data("complete".utf8)
            let context = try makeContext(payloads: ["done.txt": payload], ackFailures: ackFailures)
            try await context.engine.discoverAndSchedule()
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            let staging = context.catalog.stagingDirectory.appendingPathComponent("done.download")
            try payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
            let before = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
            await context.engine.downloadProgress(deliveryID: delivery.deliveryID, received: 1, expected: delivery.size)
            XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), before)
        }
        let context = try makeContext(payloads: ["failed.txt": Data("failed".utf8)])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        await context.engine.downloadFailed(deliveryID: delivery.deliveryID, error: URLError(.timedOut))
        let before = try XCTUnwrap(context.jobs.job(for: delivery.deliveryID))
        await context.engine.downloadProgress(deliveryID: delivery.deliveryID, received: 1, expected: delivery.size)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID), before)
    }

    func testExplicitRetryAfterTimeoutSchedulesSameDeliveryAndCompletes() async throws {
        let payload = Data("retry me".utf8)
        let context = try makeContext(payloads: ["retry.txt": payload])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        await context.scheduler.cancel(deliveryID: delivery.deliveryID)
        await context.engine.downloadFailed(deliveryID: delivery.deliveryID, error: URLError(.timedOut))
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .failed)
        try await context.engine.discoverAndSchedule()
        let automatic = await context.scheduler.scheduledIDs()
        XCTAssertTrue(automatic.isEmpty, "A transient failed job still requires an explicit retry")

        try await context.engine.retryFailedDelivery(deliveryID: delivery.deliveryID)

        let retried = await context.scheduler.scheduledIDs()
        XCTAssertEqual(retried, [delivery.deliveryID])
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .downloading)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("retry.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .completed)
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("retry.txt")), payload)
    }

    func testIntegrityFailureRemainsFailedAcrossForegroundPollAndRestore() async throws {
        let context = try makeContext(payloads: ["sha.txt": Data("good".utf8)])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        await context.scheduler.cancel(deliveryID: delivery.deliveryID)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("bad.download")
        let corrupt = Data("evil".utf8)
        try corrupt.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)

        try await context.engine.discoverAndSchedule()
        await context.engine.restore()

        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .failed)
        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(context.client.acks().isEmpty)
        XCTAssertEqual(try Data(contentsOf: staging), corrupt)
        XCTAssertTrue(try context.catalog.refresh().isEmpty)
    }

    func testForegroundPollRetriesPendingAckWithoutRedownloadOrDuplicatePhotoImport() async throws {
        let payload = Data("photo".utf8)
        let recorder = ReceivedMediaSaveRecorder()
        let context = try makeContext(payloads: ["photo.jpg": payload], ackFailures: 1,
            saveReceivedMedia: { url, contentType in
                await recorder.record(url: url, contentType: contentType)
                return true
            })
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("photo.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .ackPending)
        let scheduledBefore = await context.scheduler.scheduledIDs()

        try await context.engine.discoverAndSchedule()

        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .completed)
        XCTAssertEqual(context.client.acks().count, 1)
        let scheduledAfter = await context.scheduler.scheduledIDs()
        let imported = await recorder.values()
        XCTAssertEqual(scheduledAfter, scheduledBefore)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("photo.jpg")), payload)
    }

    func testRestoreConsumesDeliveredStagingBeforeReschedulingInterruptedJob() async throws {
        let payload = Data("orphaned download".utf8)
        let context = try makeContext(payloads: ["orphan.txt": payload])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        await context.scheduler.cancel(deliveryID: delivery.deliveryID)
        let staging = context.catalog.stagingDirectory.appendingPathComponent(
            delivery.deliveryID.uuidString.lowercased() + ".download")
        try payload.write(to: staging)

        await context.engine.restore()

        XCTAssertEqual(context.jobs.job(for: delivery.deliveryID)?.stage, .completed)
        XCTAssertEqual(context.client.acks().count, 1)
        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertTrue(scheduled.isEmpty, "A complete staging file must be verified before another download is scheduled")
        XCTAssertEqual(try? Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("orphan.txt")), payload)
    }

    func testProgressBurstIsLiveButDoesNotPersistEveryCallbackAndFailureFlushesLatestBytes() async throws {
        let clock = LocalReceiveTestClock()
        let context = try makeContext(payloads: ["progress.bin": Data(repeating: 1, count: 100)],
            now: { clock.date() })
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let diskURL = context.catalog.stagingDirectory.deletingLastPathComponent().appendingPathComponent("jobs.json")
        var durableChanges = 0
        var previousBytes = try IPhoneLocalReceiveJobStore(fileURL: diskURL).job(for: delivery.deliveryID)?.bytesReceived
        for received in 1...50 {
            await context.engine.downloadProgress(deliveryID: delivery.deliveryID, received: Int64(received), expected: 100)
            let durableBytes = try IPhoneLocalReceiveJobStore(fileURL: diskURL).job(for: delivery.deliveryID)?.bytesReceived
            if durableBytes != previousBytes { durableChanges += 1 }
            previousBytes = durableBytes
        }
        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.bytesReceived, 50)
        XCTAssertLessThanOrEqual(durableChanges, 1, "Callbacks sharing one instant should coalesce into a bounded checkpoint")
        clock.advance()
        await context.engine.downloadProgress(deliveryID: delivery.deliveryID, received: 60, expected: 100)
        XCTAssertEqual(try IPhoneLocalReceiveJobStore(fileURL: diskURL).job(for: delivery.deliveryID)?.bytesReceived, 60)
        await context.engine.downloadProgress(deliveryID: delivery.deliveryID, received: 70, expected: 100)
        await context.engine.downloadFailed(deliveryID: delivery.deliveryID, error: URLError(.timedOut))
        let terminal = try IPhoneLocalReceiveJobStore(fileURL: diskURL).job(for: delivery.deliveryID)
        XCTAssertEqual(terminal?.stage, .failed)
        XCTAssertEqual(terminal?.bytesReceived, 70, "Terminal state must immediately flush the latest live progress")
    }

    func testCancelledDiscoveryDoesNotPublishReceiveFailure() async throws {
        for cancelDuringFeatureUpdate in [false, true] {
            let context = try makeContext(payloads: [:])
            context.client.failNextDiscovery(
                duringFeatureUpdate: cancelDuringFeatureUpdate,
                code: .cancelled
            )

            await context.engine.restore()

            var updates = context.progress.updates().makeAsyncIterator()
            let latest = await updates.next()
            XCTAssertEqual(latest?.stage, .idle)
            XCTAssertNil(latest?.errorMessage)
        }
    }

    func testDiscoveryFailureAfterCompletionHasNoStaleFileAndRecoversToIdle() async throws {
        for failDuringFeatureUpdate in [false, true] {
            let payload = Data("completed file".utf8)
            let context = try makeContext(payloads: ["done.txt": payload])
            try await context.engine.discoverAndSchedule()
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            let staging = context.catalog.stagingDirectory.appendingPathComponent("done.download")
            try payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
            context.client.failNextDiscovery(duringFeatureUpdate: failDuringFeatureUpdate)

            await context.engine.restore()

            var failureUpdates = context.progress.updates().makeAsyncIterator()
            let failure = await failureUpdates.next()
            XCTAssertEqual(failure?.stage, .failed)
            XCTAssertNil(failure?.deliveryID, "A new server check is not a failure of the old file")
            XCTAssertNil(failure?.fileName)
            XCTAssertEqual(failure?.totalBytes, 0)
            XCTAssertTrue(failure?.errorMessage?.contains("네트워크") == true)

            try await context.engine.discoverAndSchedule()

            var recoveredUpdates = context.progress.updates().makeAsyncIterator()
            let recovered = await recoveredUpdates.next()
            XCTAssertEqual(recovered?.stage, .idle)
            XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .completed)
            XCTAssertEqual(try Data(contentsOf: context.catalog.receivedDirectory.appendingPathComponent("done.txt")), payload)
        }
    }

    func testEmptyInboxRemainsIdleInsteadOfShowingEndlessDiscovery() async throws {
        let context = try makeContext(payloads: [:])

        for _ in 0..<3 { try await context.engine.discoverAndSchedule() }

        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .idle)
        XCTAssertTrue(try context.jobs.load().jobs.isEmpty)
    }

    func testHealthyEmptyDiscoveryClearsOnlyTheOldDiscoveryFailure() async throws {
        let context = try makeContext(payloads: [:])
        context.progress.publishFailure("old discovery failure")

        try await context.engine.discoverAndSchedule()

        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .idle)
        XCTAssertNil(latest?.errorMessage)
    }

    func testDiscoveryAdvertisesV2PersistsBeforeSchedulingAndUsesBackgroundLease() async throws {
        let context = try makeContext(payloads: ["one.hwp": Data("one".utf8)])

        try await context.engine.discoverAndSchedule()

        let scheduledCount = await context.scheduler.scheduledIDs().count
        let durableAtSchedule = await context.scheduler.hadDurableJobWhenScheduled()
        XCTAssertEqual(context.client.featureUpdates(), [.current])
        XCTAssertEqual(context.client.leaseModes(), [.background])
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertTrue(durableAtSchedule)
        XCTAssertEqual(try context.jobs.load().jobs.count, 1)
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .downloading)
    }

    func testMatchingDownloadMovesToReceivedFilesRecordsAndAcknowledgesLocalName() async throws {
        let payload = Data("verified hwp".utf8)
        let context = try makeContext(payloads: ["업무.hwp": payload])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory
            .appendingPathComponent("incoming.download")
        try payload.write(to: staging)

        await context.engine.downloadFinished(
            deliveryID: delivery.deliveryID,
            stagingURL: staging
        )

        let stored = try XCTUnwrap(try context.catalog.refresh().first)
        XCTAssertEqual(stored.name, "업무.hwp")
        XCTAssertEqual(stored.receivedRecord?.deliveryID, delivery.deliveryID)
        XCTAssertEqual(context.client.acks(), [LocalReceiveAck(
            deliveryID: delivery.deliveryID,
            sha256: delivery.sha256,
            storageLocation: .iphoneLocal,
            storedName: "업무.hwp"
        )])
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .completed)
    }

    func testReceivedImageIsAlsoAddedToThePhotosLibrary() async throws {
        let payload = Data("received jpeg".utf8)
        let recorder = ReceivedMediaSaveRecorder()
        let context = try makeContext(
            payloads: ["현장사진.jpg": payload],
            contentTypes: ["현장사진.jpg": "image/jpeg"],
            saveReceivedMedia: { url, contentType in
                await recorder.record(url: url, contentType: contentType)
                return true
            }
        )
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("photo.download")
        try payload.write(to: staging)

        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)

        let calls = await recorder.values()
        XCTAssertEqual(calls.map(\.fileName), ["현장사진.jpg"])
        XCTAssertEqual(calls.map(\.contentType), ["image/jpeg"])
        XCTAssertEqual(try context.jobs.load().jobs.first?.mediaLibraryAdded, true)
        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .completed)
        XCTAssertTrue(latest?.errorMessage?.contains("사진 앱에도 저장") == true)
    }

    func testPhotosLibraryFailureDoesNotDeleteTheReceivedOriginal() async throws {
        let payload = Data("received png".utf8)
        let context = try makeContext(
            payloads: ["현장사진.png": payload],
            contentTypes: ["현장사진.png": "image/png"],
            saveReceivedMedia: { _, _ in throw IPhoneReceivedMediaLibraryError.permissionDenied }
        )
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("photo.download")
        try payload.write(to: staging)

        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)

        let stored = try XCTUnwrap(try context.catalog.refresh().first)
        XCTAssertEqual(try Data(contentsOf: stored.url), payload)
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .completed)
        XCTAssertEqual(try context.jobs.load().jobs.first?.mediaLibraryAdded, false)
        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .completed)
        XCTAssertTrue(latest?.errorMessage?.contains("사진 앱 추가 실패") == true)
    }

    func testZeroByteFinalizesAndVerifyingProgressIsOneHundredPercent() async throws {
        let context = try makeContext(payloads: ["empty.txt": Data()])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory
            .appendingPathComponent("empty.download")
        XCTAssertTrue(FileManager.default.createFile(atPath: staging.path, contents: Data()))

        await context.engine.downloadFinished(
            deliveryID: delivery.deliveryID,
            stagingURL: staging
        )

        XCTAssertEqual(try context.catalog.refresh().first?.size, 0)
        XCTAssertEqual(USBReceiveProgress(
            stage: .verifying,
            destination: .iphoneLocal,
            deliveryID: delivery.deliveryID,
            fileName: delivery.fileName,
            currentIndex: 1,
            totalCount: 1,
            completedCount: 0,
            bytesReceived: 0,
            totalBytes: 0,
            startedAt: Date(),
            expiresAt: delivery.expiresAt,
            errorMessage: nil
        ).percent, 100)
    }

    func testSHAMismatchKeepsStagingFailedAndDoesNotAcknowledge() async throws {
        let context = try makeContext(payloads: ["report.pdf": Data("good".utf8)])
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory
            .appendingPathComponent("wrong.download")
        try Data("bad".utf8).write(to: staging)

        await context.engine.downloadFinished(
            deliveryID: delivery.deliveryID,
            stagingURL: staging
        )

        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(context.client.acks(), [])
        XCTAssertEqual(try context.catalog.refresh(), [])
        var updates = context.progress.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .failed)
        XCTAssertEqual(latest?.deliveryID, delivery.deliveryID)
        XCTAssertNotNil(latest?.errorMessage)

        context.client.failNextDiscovery(duringFeatureUpdate: false)
        await context.engine.restore()
        try await context.engine.discoverAndSchedule()
        var afterRecovery = context.progress.updates().makeAsyncIterator()
        let stillFailed = await afterRecovery.next()
        XCTAssertEqual(stillFailed?.stage, .failed)
        XCTAssertEqual(stillFailed?.deliveryID, delivery.deliveryID)
    }

    func testAckFailureKeepsFinalFileAndRestoreRetriesOnlyAck() async throws {
        let payload = Data("ack pending".utf8)
        let context = try makeContext(
            payloads: ["pending.zip": payload],
            ackFailures: 1
        )
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory
            .appendingPathComponent("pending.download")
        try payload.write(to: staging)

        await context.engine.downloadFinished(
            deliveryID: delivery.deliveryID,
            stagingURL: staging
        )
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .ackPending)
        XCTAssertEqual(try context.catalog.refresh().map(\.name), ["pending.zip"])
        var pendingUpdates = context.progress.updates().makeAsyncIterator()
        let pendingProgress = await pendingUpdates.next()
        XCTAssertEqual(pendingProgress?.stage.rawValue, "receiptPending",
                       "Verified local storage is not a failed download")
        let scheduledBefore = await context.scheduler.scheduledIDs().count

        await context.engine.restore()

        let scheduledAfter = await context.scheduler.scheduledIDs().count
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .completed)
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(scheduledAfter, scheduledBefore)
    }

    func testCanceledServerReceiptPreservesVerifiedLocalFileAndDoesNotRetry() async throws {
        for code in ["delivery canceled", "delivery expired"] {
            let payload = Data("verified original".utf8)
            let context = try makeContext(payloads: ["saved.zip": payload], ackFailures: 10,
                                          ackError: .server(statusCode: 410, code: code))
            try await context.engine.discoverAndSchedule()
            let delivery = try XCTUnwrap(context.client.deliveries().first)
            let staging = context.catalog.stagingDirectory.appendingPathComponent("saved.download")
            try payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
            XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .savedWithoutReceipt)
            let saved = try XCTUnwrap(context.catalog.refresh().first)
            XCTAssertEqual(try Data(contentsOf: saved.url), payload)
            let scheduled = await context.scheduler.scheduledIDs().count
            await context.engine.restore()
            let restored = await context.scheduler.scheduledIDs().count
            XCTAssertEqual(restored, scheduled)
            XCTAssertEqual(context.client.acks().count, 0)
        }
    }

    func testUnknownConflictDoesNotClaimReceiptSuccess() async throws {
        let payload = Data("keep pending".utf8)
        let context = try makeContext(payloads: ["pending.bin": payload], ackFailures: 10,
                                      ackError: .server(statusCode: 409, code: "delivery cannot be acknowledged"))
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("pending.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .ackPending)
        XCTAssertEqual(try context.catalog.refresh().count, 1)
        XCTAssertEqual(context.client.acks().count, 0)
    }

    func testRestoreDoesNotClaimNewDeliveryWhenAutomaticDiscoveryIsDisabled() async throws {
        let context = try makeContext(
            payloads: ["usb-target.txt": Data("USB only".utf8)],
            automaticDiscoveryAllowed: { false }
        )

        await context.engine.restore()

        let scheduledBefore = await context.scheduler.scheduledIDs()
        XCTAssertTrue(context.client.featureUpdates().isEmpty)
        XCTAssertTrue(context.client.leaseModes().isEmpty)
        XCTAssertTrue(try context.jobs.load().jobs.isEmpty)
        XCTAssertTrue(scheduledBefore.isEmpty)

        try await context.engine.discoverAndSchedule(force: true)
        let scheduledAfter = await context.scheduler.scheduledIDs().count
        XCTAssertEqual(scheduledAfter, 1)
    }

    func testProgressKeepsOneStartTimeForTheSameDownload() async throws {
        let clock = LocalReceiveTestClock()
        let context = try makeContext(
            payloads: ["progress.txt": Data("progress".utf8)],
            now: { clock.date() }
        )
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        var updates = context.progress.updates().makeAsyncIterator()
        let first = await updates.next()

        clock.advance()
        await context.engine.downloadProgress(
            deliveryID: delivery.deliveryID,
            received: 4,
            expected: delivery.size
        )
        let second = await updates.next()

        XCTAssertNotNil(first?.startedAt)
        XCTAssertEqual(second?.startedAt, first?.startedAt)
    }

    func testCollisionAndLongNameKeepValidSuffixAndExtension() throws {
        let directory = temporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("README"))

        let collision = try IPhoneLocalFileNaming.availableName(
            requestedName: "README",
            in: directory
        )
        let long = try IPhoneLocalFileNaming.availableName(
            requestedName: String(repeating: "가", count: 100) + ".hwp",
            in: directory
        )

        XCTAssertEqual(collision, "README (1)")
        XCTAssertTrue(long.hasSuffix(".hwp"))
        XCTAssertLessThanOrEqual(long.lengthOfBytes(using: .utf8), 240)
    }

    func testActualLocalReceiveCompletionNotifiesOnceAndFollowingDiscoveryFailureIsSilent() async throws {
        let payload = Data("local receive contents".utf8)
        let context = try makeContext(payloads: ["local.pdf": payload])
        let events = LocalReceiveNotificationEventRecorder()
        context.progress.setTransferEventHandler { events.append($0) }
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("local.download")
        try payload.write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        XCTAssertEqual(events.values.map(\.operation), [.receive])
        XCTAssertEqual(events.values.map(\.outcome), [.completed])
        context.client.failNextDiscovery(duringFeatureUpdate: false)
        await context.engine.restore()
        XCTAssertEqual(events.values.map(\.outcome), [.completed], "Discovery must not reuse the last receive identity")
        await context.engine.restore()
        XCTAssertEqual(events.values.count, 1, "Historical progress must not replay a completion")
    }

    func testSequentialLocalReceiveJobsHaveDistinctCompletionIdentity() async throws {
        let payloads = ["first.pdf": Data("first".utf8), "second.pdf": Data("second".utf8)]
        let context = try makeContext(payloads: payloads)
        let events = LocalReceiveNotificationEventRecorder()
        context.progress.setTransferEventHandler { events.append($0) }
        try await context.engine.discoverAndSchedule()
        for _ in 0..<payloads.count {
            let delivery = try XCTUnwrap(context.jobs.load().jobs.first { $0.stage == .downloading }).delivery
            let staging = context.catalog.stagingDirectory.appendingPathComponent("\(delivery.deliveryID).download")
            try XCTUnwrap(payloads[delivery.fileName]).write(to: staging)
            await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        }
        XCTAssertEqual(events.values.map(\.outcome), [.completed, .completed])
        XCTAssertEqual(Set(events.values.map(\.jobID)).count, 2)
    }

    func testLocalReceiveIntegrityFailureProducesActualJobFailureNotification() async throws {
        let context = try makeContext(payloads: ["local.pdf": Data("expected".utf8)])
        let events = LocalReceiveNotificationEventRecorder()
        context.progress.setTransferEventHandler { events.append($0) }
        try await context.engine.discoverAndSchedule()
        let delivery = try XCTUnwrap(context.client.deliveries().first)
        let staging = context.catalog.stagingDirectory.appendingPathComponent("local.download")
        try Data("corrupt".utf8).write(to: staging)
        await context.engine.downloadFinished(deliveryID: delivery.deliveryID, stagingURL: staging)
        XCTAssertEqual(events.values.map(\.outcome), [.failed])
        XCTAssertEqual(events.values.first?.operation, .receive)
        XCTAssertTrue(context.client.acks().isEmpty)
    }

    private func makeContext(
        payloads: [String: Data],
        contentTypes: [String: String] = [:],
        ackFailures: Int = 0,
        ackError: IPhoneReceiverClientError? = nil,
        automaticDiscoveryAllowed: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 500) },
        saveReceivedMedia: @escaping IPhoneLocalReceiveEngine.SaveReceivedMedia = { _, _ in false }
    ) throws -> LocalReceiveContext {
        let root = temporaryDirectory()
        let deliveries = payloads.map { name, payload in
            IPhoneDelivery(
                deliveryID: UUID(),
                fileName: name,
                contentType: contentTypes[name] ?? "application/octet-stream",
                size: Int64(payload.count),
                sha256: Self.sha256(payload),
                state: .available,
                createdAt: Date(timeIntervalSince1970: 100),
                expiresAt: Date(timeIntervalSince1970: 10_000),
                deliveredAt: nil
            )
        }.sorted { $0.fileName < $1.fileName }
        let client = FakeLocalReceiveClient(
            deliveries: deliveries,
            ackFailures: ackFailures,
            ackError: ackError
        )
        let jobs = try IPhoneLocalReceiveJobStore(
            fileURL: root.appendingPathComponent("jobs.json")
        )
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("받은 파일", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("ReceiveStaging", isDirectory: true),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        let scheduler = FakeLocalReceiveScheduler(jobStore: jobs)
        let progress = USBReceiveProgressStore()
        let credentials = IPhoneReceiverCredentials(
            identity: IPhoneReceiverIdentity(
                receiverID: UUID(),
                code: "123456",
                deviceName: "희종의 iPhone"
            ),
            secret: "receive-secret"
        )
        let engine = IPhoneLocalReceiveEngine(
            client: client,
            scheduler: scheduler,
            jobStore: jobs,
            catalog: catalog,
            credentials: { credentials },
            automaticDiscoveryAllowed: automaticDiscoveryAllowed,
            progressStore: progress,
            now: now,
            saveReceivedMedia: saveReceivedMedia
        )
        return LocalReceiveContext(
            engine: engine,
            client: client,
            scheduler: scheduler,
            jobs: jobs,
            catalog: catalog,
            progress: progress
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor ReceivedMediaSaveRecorder {
    struct Value: Equatable {
        let fileName: String
        let contentType: String
    }

    private var records: [Value] = []

    func record(url: URL, contentType: String) {
        records.append(Value(fileName: url.lastPathComponent, contentType: contentType))
    }

    func values() -> [Value] { records }
}

private struct LocalReceiveContext {
    let engine: IPhoneLocalReceiveEngine
    let client: FakeLocalReceiveClient
    let scheduler: FakeLocalReceiveScheduler
    let jobs: IPhoneLocalReceiveJobStore
    let catalog: IPhoneReceivedFileCatalog
    let progress: USBReceiveProgressStore
}

private final class LocalReceiveTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 500)

    func date() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value = value.addingTimeInterval(10) } }
}

private struct LocalReceiveAck: Equatable {
    let deliveryID: UUID
    let sha256: String
    let storageLocation: IPhoneStorageLocation
    let storedName: String
}

private final class FakeLocalReceiveClient: IPhoneLocalReceiveNetworking,
    @unchecked Sendable {
    private let lock = NSLock()
    private let availableDeliveries: [IPhoneDelivery]
    private var advertisedFeatures: [IPhoneReceiveFeatures] = []
    private var modes: [IPhoneReceiveLeaseMode] = []
    private var successfulAcks: [LocalReceiveAck] = []
    private var remainingAckFailures: Int
    private let ackError: IPhoneReceiverClientError?
    private var featureUpdateFailure: URLError.Code?
    private var listingFailure: URLError.Code?
    private var acknowledgementGate: LocalReceiveAckGate?
    private var leaseGate: LocalReceiveEnumerationGate?

    init(deliveries: [IPhoneDelivery], ackFailures: Int, ackError: IPhoneReceiverClientError? = nil) {
        availableDeliveries = deliveries
        remainingAckFailures = ackFailures
        self.ackError = ackError
    }

    func updateFeatures(
        receiverID: UUID,
        receiveSecret: String,
        features: IPhoneReceiveFeatures
    ) async throws {
        try lock.withLock {
            if let code = featureUpdateFailure {
                featureUpdateFailure = nil
                throw URLError(code)
            }
            advertisedFeatures.append(features)
        }
    }

    func list(receiverID: UUID, receiveSecret: String) async throws -> [IPhoneDelivery] {
        try lock.withLock {
            if let code = listingFailure {
                listingFailure = nil
                throw URLError(code)
            }
            return availableDeliveries
        }
    }

    func failNextDiscovery(
        duringFeatureUpdate: Bool,
        code: URLError.Code = .notConnectedToInternet
    ) {
        lock.withLock {
            featureUpdateFailure = duringFeatureUpdate ? code : nil
            listingFailure = duringFeatureUpdate ? nil : code
        }
    }

    func lease(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        mode: IPhoneReceiveLeaseMode
    ) async throws -> IPhoneDelivery {
        lock.withLock { modes.append(mode) }
        let gate = lock.withLock { leaseGate }
        await gate?.wait()
        return availableDeliveries.first { $0.deliveryID == deliveryID }!
    }

    func downloadRequest(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String
    ) throws -> URLRequest {
        URLRequest(url: URL(string: "https://relay.example/\(deliveryID)")!)
    }

    func range(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        start: Int64,
        end: Int64
    ) async throws -> IPhoneReceiverRangeChunk {
        throw LocalReceiveTestError.unsupported
    }

    func acknowledge(
        receiverID: UUID,
        deliveryID: UUID,
        receiveSecret: String,
        sha256: String,
        storageLocation: IPhoneStorageLocation,
        storedName: String
    ) async throws {
        let gate = lock.withLock { acknowledgementGate }
        await gate?.wait()
        try lock.withLock {
            if remainingAckFailures > 0 {
                remainingAckFailures -= 1
                if let ackError { throw ackError }
                throw LocalReceiveTestError.ackFailed
            }
            successfulAcks.append(LocalReceiveAck(
                deliveryID: deliveryID,
                sha256: sha256,
                storageLocation: storageLocation,
                storedName: storedName
            ))
        }
    }

    func deliveries() -> [IPhoneDelivery] { availableDeliveries }
    func setAcknowledgementGate(_ gate: LocalReceiveAckGate) {
        lock.withLock { acknowledgementGate = gate }
    }
    func setLeaseGate(_ gate: LocalReceiveEnumerationGate) {
        lock.withLock { leaseGate = gate }
    }
    func featureUpdates() -> [IPhoneReceiveFeatures] {
        lock.withLock { advertisedFeatures }
    }
    func leaseModes() -> [IPhoneReceiveLeaseMode] { lock.withLock { modes } }
    func acks() -> [LocalReceiveAck] { lock.withLock { successfulAcks } }
}

private final class LocalReceiveTestSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var fulfilled = false
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func fulfill() {
        lock.withLock {
            guard !fulfilled else { return }
            fulfilled = true
            expectation.fulfill()
        }
    }
}

private actor LocalReceiveAckGate {
    private let firstEntered: XCTestExpectation
    private let secondBoundary: LocalReceiveTestSignal
    private var count = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(firstEntered: XCTestExpectation, secondBoundary: LocalReceiveTestSignal) {
        self.firstEntered = firstEntered
        self.secondBoundary = secondBoundary
    }
    func wait() async {
        count += 1
        if count == 1 { firstEntered.fulfill() }
        else { secondBoundary.fulfill() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func enteredCount() -> Int { count }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum LocalReceiveTestError: Error {
    case unsupported
    case ackFailed
}

private actor FakeLocalReceiveScheduler: IPhoneReceiveTaskScheduling {
    private let jobStore: IPhoneLocalReceiveJobStore
    private var scheduled: [UUID] = []
    private var durableAtSchedule = false
    private var enumerationGate: LocalReceiveEnumerationGate?
    private var scheduleGate: LocalReceiveEnumerationGate?

    init(jobStore: IPhoneLocalReceiveJobStore) {
        self.jobStore = jobStore
    }

    func schedule(deliveryID: UUID, request: URLRequest) async throws {
        await scheduleGate?.wait()
        durableAtSchedule = jobStore.job(for: deliveryID) != nil
        scheduled.append(deliveryID)
    }

    func existingDeliveryIDs() async -> Set<UUID> {
        await enumerationGate?.wait()
        return Set(scheduled)
    }

    func setEnumerationGate(_ gate: LocalReceiveEnumerationGate) { enumerationGate = gate }
    func setScheduleGate(_ gate: LocalReceiveEnumerationGate) { scheduleGate = gate }

    func cancel(deliveryID: UUID) async {
        scheduled.removeAll { $0 == deliveryID }
    }

    func scheduledIDs() -> [UUID] { scheduled }
    func hadDurableJobWhenScheduled() -> Bool { durableAtSchedule }
}

private actor LocalReceiveEnumerationGate {
    private let entered: XCTestExpectation
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class HTTPFailureReceiveDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    var status = 503
    override var response: URLResponse? {
        HTTPURLResponse(url: URL(string: "https://example.invalid/download")!,
            statusCode: status, httpVersion: nil, headerFields: nil)
    }
}
