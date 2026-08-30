import CryptoKit
import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneLocalReceiveEngineTests: XCTestCase {
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
        let scheduledBefore = await context.scheduler.scheduledIDs().count

        await context.engine.restore()

        let scheduledAfter = await context.scheduler.scheduledIDs().count
        XCTAssertEqual(try context.jobs.load().jobs.first?.stage, .completed)
        XCTAssertEqual(context.client.acks().count, 1)
        XCTAssertEqual(scheduledAfter, scheduledBefore)
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

    private func makeContext(
        payloads: [String: Data],
        ackFailures: Int = 0,
        automaticDiscoveryAllowed: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 500) }
    ) throws -> LocalReceiveContext {
        let root = temporaryDirectory()
        let deliveries = payloads.map { name, payload in
            IPhoneDelivery(
                deliveryID: UUID(),
                fileName: name,
                contentType: "application/octet-stream",
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
            ackFailures: ackFailures
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
            now: now
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
    private var featureUpdateFailure: URLError.Code?
    private var listingFailure: URLError.Code?

    init(deliveries: [IPhoneDelivery], ackFailures: Int) {
        availableDeliveries = deliveries
        remainingAckFailures = ackFailures
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
        try lock.withLock {
            if remainingAckFailures > 0 {
                remainingAckFailures -= 1
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
    func featureUpdates() -> [IPhoneReceiveFeatures] {
        lock.withLock { advertisedFeatures }
    }
    func leaseModes() -> [IPhoneReceiveLeaseMode] { lock.withLock { modes } }
    func acks() -> [LocalReceiveAck] { lock.withLock { successfulAcks } }
}

private enum LocalReceiveTestError: Error {
    case unsupported
    case ackFailed
}

private actor FakeLocalReceiveScheduler: IPhoneReceiveTaskScheduling {
    private let jobStore: IPhoneLocalReceiveJobStore
    private var scheduled: [UUID] = []
    private var durableAtSchedule = false

    init(jobStore: IPhoneLocalReceiveJobStore) {
        self.jobStore = jobStore
    }

    func schedule(deliveryID: UUID, request: URLRequest) async throws {
        durableAtSchedule = jobStore.job(for: deliveryID) != nil
        scheduled.append(deliveryID)
    }

    func existingDeliveryIDs() async -> Set<UUID> { Set(scheduled) }

    func cancel(deliveryID: UUID) async {
        scheduled.removeAll { $0 == deliveryID }
    }

    func scheduledIDs() -> [UUID] { scheduled }
    func hadDurableJobWhenScheduled() -> Bool { durableAtSchedule }
}
