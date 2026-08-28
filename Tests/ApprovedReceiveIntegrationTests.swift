import CryptoKit
import XCTest
@testable import SimpleCameraAutoSender

final class ApprovedReceiveIntegrationTests: XCTestCase {
    func testConcurrentDiscoveryCannotLeaseOrScheduleTheSameFileTwice() async throws {
        let gate = ApprovedReceiveListGate()
        let context = try makeContext(count: 1, listGate: gate)
        let id = context.transport.files[0].deliveryID
        try context.approvals.approve([id], receiverID: context.receiver, destination: .iphoneLocal)
        let first = Task { try await context.engine.discoverAndSchedule(force: true) }
        await waitUntil { context.transport.listCallCount == 1 }
        let secondFinished = ApprovedReceiveCompletion()
        let second = Task {
            defer { secondFinished.finish() }
            try await context.engine.discoverAndSchedule(force: true)
        }
        await waitUntil { secondFinished.isFinished || context.transport.listCallCount > 1 }
        XCTAssertEqual(context.transport.listCallCount, 1, "A second discovery must not enter while the first is awaiting the server")
        await gate.open()
        try await first.value
        try await second.value
        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertEqual(scheduled, [id])
    }

    func testConcurrentUSBPollingDoesNotStartASecondRun() async throws {
        let gate = ApprovedReceiveListGate()
        let context = try makeContext(count: 0, listGate: gate)
        let ledger = try USBReceiveLedger(fileURL: context.catalog.stagingDirectory.appendingPathComponent("usb-ledger.json"))
        let credentials = IPhoneReceiverCredentials(identity: IPhoneReceiverIdentity(receiverID: context.receiver, code: "123456", deviceName: "Test iPhone"), secret: "test-secret")
        let service = USBReceiveService(
            client: IPhoneReceiverClient(transport: context.transport),
            ledger: ledger,
            credentials: { credentials },
            destination: { nil }
        )
        let first = Task { try await service.runOnce() }
        await waitUntil { context.transport.listCallCount == 1 }
        let secondFinished = ApprovedReceiveCompletion()
        let second = Task {
            defer { secondFinished.finish() }
            return try await service.runOnce()
        }
        await waitUntil { secondFinished.isFinished || context.transport.listCallCount > 1 }
        XCTAssertEqual(context.transport.listCallCount, 1)
        await gate.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertTrue(ledger.allCheckpoints().isEmpty)
    }

    func testRestorationCannotStartNewFilesWithoutAChoice() async throws {
        let context = try makeContext(count: 2)
        await context.engine.restore()

        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertTrue(try context.jobs.load().jobs.isEmpty)
        XCTAssertTrue(context.transport.leasedIDs.isEmpty)
        XCTAssertTrue(try context.catalog.refresh().isEmpty)
    }

    func testTenApprovedFilesDownloadOneByOneButAnEleventhStaysPending() async throws {
        let context = try makeContext(count: 11)
        let approved = Array(context.transport.files.prefix(10))
        let selectedIDs = Set(approved.map(\.deliveryID))
        try context.approvals.approve(selectedIDs, receiverID: context.receiver, destination: .iphoneLocal)
        try await context.engine.discoverAndSchedule(force: true)

        for index in 0..<10 {
            let scheduled = await context.scheduler.scheduledIDs()
            XCTAssertEqual(scheduled.count, index + 1, "Only one approved file is scheduled at a time")
            let id = try XCTUnwrap(scheduled.last)
            let staging = context.catalog.stagingDirectory.appendingPathComponent(id.uuidString)
            try context.transport.payload.write(to: staging)
            await context.engine.downloadFinished(deliveryID: id, stagingURL: staging)
        }

        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertEqual(Set(scheduled), selectedIDs)
        XCTAssertEqual(try context.catalog.refresh().count, 10)
        XCTAssertEqual(context.transport.ackedIDs, selectedIDs)
        XCTAssertFalse(scheduled.contains(context.transport.files[10].deliveryID))
    }

    func testUSBChoiceDoesNotEnterLocalBackgroundDownload() async throws {
        let context = try makeContext(count: 1)
        let id = context.transport.files[0].deliveryID
        try context.approvals.approve([id], receiverID: context.receiver, destination: .usb)
        try await context.engine.discoverAndSchedule(force: true)

        let scheduled = await context.scheduler.scheduledIDs()
        XCTAssertTrue(scheduled.isEmpty)
        let usbClient = IPhoneReceiverClient(transport: context.transport, allowedDeliveryIDs: { receiver in
            try context.approvals.allowedDeliveryIDs(receiverID: receiver, destination: .usb)
        })
        let usbFiles = try await usbClient.list(receiverID: context.receiver, receiveSecret: "test-secret")
        XCTAssertEqual(usbFiles.map(\.deliveryID), [id])
    }

    func testDiscoveryClientSeesFilesWhileBothReceiveClientsDenyUnapprovedFiles() async throws {
        let context = try makeContext(count: 3)
        let discovery = IPhoneReceiverClient(transport: context.transport)
        let listed = try await discovery.list(receiverID: context.receiver, receiveSecret: "test-secret")
        XCTAssertEqual(listed.count, 3)

        for destination in IPhoneReceiveDestination.allCases {
            let receiver = IPhoneReceiverClient(transport: context.transport, allowedDeliveryIDs: { id in
                try context.approvals.allowedDeliveryIDs(receiverID: id, destination: destination)
            })
            let allowed = try await receiver.list(receiverID: context.receiver, receiveSecret: "test-secret")
            XCTAssertTrue(allowed.isEmpty)
        }
        XCTAssertTrue(context.transport.leasedIDs.isEmpty)
        XCTAssertTrue(context.transport.ackedIDs.isEmpty)
    }

    private func makeContext(count: Int, listGate: ApprovedReceiveListGate? = nil) throws -> Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let receiver = UUID()
        let approvals = IPhoneReceiveApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let transport = ApprovedReceiveTransport(count: count, listGate: listGate)
        let client = IPhoneReceiverClient(transport: transport, allowedDeliveryIDs: { id in
            try approvals.allowedDeliveryIDs(receiverID: id, destination: .iphoneLocal)
        })
        let jobs = try IPhoneLocalReceiveJobStore(fileURL: root.appendingPathComponent("jobs.json"))
        let catalog = try IPhoneReceivedFileCatalog(
            receivedDirectory: root.appendingPathComponent("received"),
            stagingDirectory: root.appendingPathComponent("staging"),
            recordsFileURL: root.appendingPathComponent("records.json")
        )
        let scheduler = ApprovedReceiveScheduler()
        let credentials = IPhoneReceiverCredentials(identity: IPhoneReceiverIdentity(receiverID: receiver, code: "123456", deviceName: "Test iPhone"), secret: "test-secret")
        let engine = IPhoneLocalReceiveEngine(client: client, scheduler: scheduler, jobStore: jobs, catalog: catalog, credentials: { credentials }, progressStore: USBReceiveProgressStore())
        return Context(engine: engine, scheduler: scheduler, approvals: approvals, transport: transport, jobs: jobs, catalog: catalog, receiver: receiver)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The test request did not reach its expected boundary")
    }

    private struct Context: Sendable {
        let engine: IPhoneLocalReceiveEngine
        let scheduler: ApprovedReceiveScheduler
        let approvals: IPhoneReceiveApprovalStore
        let transport: ApprovedReceiveTransport
        let jobs: IPhoneLocalReceiveJobStore
        let catalog: IPhoneReceivedFileCatalog
        let receiver: UUID
    }
}

private actor ApprovedReceiveScheduler: IPhoneReceiveTaskScheduling {
    private var ids: [UUID] = []
    func schedule(deliveryID: UUID, request: URLRequest) async throws { ids.append(deliveryID) }
    func existingDeliveryIDs() async -> Set<UUID> { Set(ids) }
    func cancel(deliveryID: UUID) async {}
    func scheduledIDs() -> [UUID] { ids }
}

private final class ApprovedReceiveTransport: IPhoneReceiverTransport, @unchecked Sendable {
    let payload = Data("simulation data only".utf8)
    let files: [IPhoneDelivery]
    private let lock = NSLock()
    private var leased: Set<UUID> = []
    private var acked: Set<UUID> = []
    private var listCalls = 0
    private let listGate: ApprovedReceiveListGate?

    init(count: Int, listGate: ApprovedReceiveListGate? = nil) {
        self.listGate = listGate
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let size = Int64(payload.count)
        files = (0..<count).map {
            IPhoneDelivery(deliveryID: UUID(), fileName: "simulation-\($0).txt", contentType: "text/plain", size: size, sha256: hash, state: .available, createdAt: Date(timeIntervalSince1970: Double($0)), expiresAt: .distantFuture, deliveredAt: nil)
        }
    }

    var leasedIDs: Set<UUID> { lock.withLock { leased } }
    var ackedIDs: Set<UUID> { lock.withLock { acked } }
    var listCallCount: Int { lock.withLock { listCalls } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        switch url.lastPathComponent {
        case "features": data = Data()
        case "deliveries":
            lock.withLock { listCalls += 1 }
            await listGate?.wait()
            let acknowledged = ackedIDs
            data = try encoder.encode(files.filter { !acknowledged.contains($0.deliveryID) })
        case "lease":
            let id = try XCTUnwrap(UUID(uuidString: url.deletingLastPathComponent().lastPathComponent))
            _ = lock.withLock { leased.insert(id) }
            data = try encoder.encode(try XCTUnwrap(files.first { $0.deliveryID == id }))
        case "ack":
            let id = try XCTUnwrap(UUID(uuidString: url.deletingLastPathComponent().lastPathComponent))
            _ = lock.withLock { acked.insert(id) }
            data = Data()
        default: throw URLError(.unsupportedURL)
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ApprovedReceiveListGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class ApprovedReceiveCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}
