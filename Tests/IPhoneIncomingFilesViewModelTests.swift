import XCTest
@testable import SimpleCameraAutoSender

@MainActor
final class IPhoneIncomingFilesViewModelTests: XCTestCase {
    func testInactiveAppDoesNotPollOrPresent() async throws {
        let context = try makeContext(count: 1)
        await context.model.refresh()
        XCTAssertEqual(context.server.callCount, 0)
        XCTAssertNil(context.model.prompt)
    }

    func testActivationDetectsTenFilesWithoutApprovingAnyDownload() async throws {
        let context = try makeContext(count: 10)
        await activate(context)

        XCTAssertEqual(context.model.pendingFiles.count, 10)
        XCTAssertEqual(context.model.prompt?.files.count, 10)
        XCTAssertEqual(context.model.prompt?.totalBytes, 55_000)
        XCTAssertTrue(try context.store.destinations(receiverID: context.server.receiverID).isEmpty)
    }

    func testPostponedBatchDoesNotReopenEveryPollAndCanBeReopenedManually() async throws {
        let context = try makeContext(count: 2)
        await activate(context)
        context.model.postponePrompt()
        for _ in 0..<10 { await context.model.refresh() }
        XCTAssertNil(context.model.prompt)
        XCTAssertEqual(context.model.pendingFiles.count, 2)

        context.model.showPendingFiles()
        XCTAssertEqual(context.model.prompt?.files.count, 2)
        XCTAssertTrue(try context.store.destinations(receiverID: context.server.receiverID).isEmpty)
    }

    func testUSBChoiceApprovesAllTenFilesAndNoMore() async throws {
        let context = try makeContext(count: 10)
        await activate(context)
        let batch = try XCTUnwrap(context.model.prompt)

        XCTAssertTrue(context.model.accept(batch, destination: .usb))
        await context.model.refresh()

        XCTAssertNil(context.model.prompt)
        XCTAssertTrue(context.model.pendingFiles.isEmpty)
        XCTAssertEqual(try context.store.destinations(receiverID: batch.receiverID), Dictionary(uniqueKeysWithValues: batch.files.map { ($0.deliveryID, IPhoneReceiveDestination.usb) }))
    }

    func testNewArrivalDoesNotJoinAlreadyDisplayedBatch() async throws {
        let context = try makeContext(count: 1)
        await activate(context)
        let batch = try XCTUnwrap(context.model.prompt)
        let newFile = file(index: 2)
        context.server.append(newFile)
        await context.model.refresh()
        XCTAssertEqual(context.model.prompt?.files.map(\.deliveryID), batch.files.map(\.deliveryID))

        XCTAssertTrue(context.model.accept(batch, destination: .iphoneLocal))
        await context.model.refresh()

        let choices = try context.store.destinations(receiverID: batch.receiverID)
        XCTAssertEqual(choices.count, 1)
        XCTAssertNil(choices[newFile.deliveryID])
        XCTAssertEqual(context.model.prompt?.files.map(\.deliveryID), [newFile.deliveryID])
    }

    func testNewBatchDoesNotSilentlyIncludePostponedFiles() async throws {
        let context = try makeContext(count: 1)
        await activate(context)
        let postponed = try XCTUnwrap(context.model.prompt?.files.first)
        context.model.postponePrompt()
        let next = file(index: 2)
        context.server.append(next)
        await context.model.refresh()

        let batch = try XCTUnwrap(context.model.prompt)
        XCTAssertEqual(batch.files.map(\.deliveryID), [next.deliveryID])
        XCTAssertTrue(context.model.accept(batch, destination: .usb))
        XCTAssertNil(try context.store.destinations(receiverID: batch.receiverID)[postponed.deliveryID])
        XCTAssertEqual(context.model.pendingFiles.map(\.deliveryID), [postponed.deliveryID])
    }

    func testAcknowledgingAndDeliveredFilesNeverAppearAsNew() async throws {
        let context = try makeContext(count: 0)
        context.server.replace([file(index: 1, state: .ackDeleting), file(index: 2, state: .delivered)])
        await activate(context)
        XCTAssertTrue(context.model.pendingFiles.isEmpty)
        XCTAssertNil(context.model.prompt)
    }

    func testDisappearedFilesCloseThePromptAndCannotBeApproved() async throws {
        let context = try makeContext(count: 1)
        await activate(context)
        let batch = try XCTUnwrap(context.model.prompt)
        context.server.replace([])
        await context.model.refresh()

        XCTAssertNil(context.model.prompt)
        XCTAssertFalse(context.model.accept(batch, destination: .usb))
        XCTAssertTrue(try context.store.destinations(receiverID: batch.receiverID).isEmpty)
    }

    func testOfflinePollRetainsPendingFilesAndRecoveryClearsError() async throws {
        let context = try makeContext(count: 2)
        await activate(context)
        context.model.postponePrompt()
        context.server.error = URLError(.notConnectedToInternet)
        await context.model.refresh()
        XCTAssertEqual(context.model.pendingFiles.count, 2)
        XCTAssertNotNil(context.model.lastError)
        XCTAssertNil(context.model.prompt)

        context.server.error = nil
        await context.model.refresh()
        XCTAssertNil(context.model.lastError)
        XCTAssertEqual(context.model.pendingFiles.count, 2)
    }

    func testFailedChoicePersistenceRetainsFilesAndDoesNotNavigate() async throws {
        let context = try makeContext(count: 1, failApprovals: true)
        await activate(context)
        let batch = try XCTUnwrap(context.model.prompt)

        XCTAssertFalse(context.model.accept(batch, destination: .iphoneLocal))
        XCTAssertEqual(context.model.pendingFiles.count, 1)
        XCTAssertNotNil(context.model.lastError)
        XCTAssertTrue(try context.store.destinations(receiverID: batch.receiverID).isEmpty)
    }

    func testReceiverChangeInvalidatesTheOldPrompt() async throws {
        let context = try makeContext(count: 1)
        await activate(context)
        let old = try XCTUnwrap(context.model.prompt)
        context.server.receiverID = UUID()
        context.server.replace([file(index: 2)])
        await context.model.refresh()

        XCTAssertEqual(context.model.prompt?.receiverID, context.server.receiverID)
        XCTAssertFalse(context.model.accept(old, destination: .usb))
        XCTAssertTrue(try context.store.destinations(receiverID: old.receiverID).isEmpty)
    }

    func testLateResponseAfterBackgroundingIsIgnoredAndReturnChecksAgain() async throws {
        let context = try makeContext(count: 1)
        let gate = ArrivalQueryGate()
        context.server.gate = gate
        context.model.setActive(true)
        await waitUntil { context.server.callCount == 1 }
        context.model.setActive(false)
        await gate.open()
        await waitUntil { context.server.completedCalls == 1 }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(context.model.prompt)
        XCTAssertTrue(context.model.pendingFiles.isEmpty)

        context.server.gate = nil
        await activate(context)
        XCTAssertEqual(context.model.pendingFiles.count, 1)
    }

    func testRepeatedActivationDoesNotStartDuplicateQueries() async throws {
        let context = try makeContext(count: 1)
        let gate = ArrivalQueryGate()
        context.server.gate = gate
        context.model.setActive(true)
        await waitUntil { context.server.callCount == 1 }
        context.model.setActive(true)
        await context.model.refresh()
        XCTAssertEqual(context.server.callCount, 1)
        await gate.open()
        await waitUntil { context.model.pendingFiles.count == 1 }
    }

    private func activate(_ context: Context) async {
        context.model.setActive(true)
        await waitUntil { context.server.completedCalls > 0 && (context.model.prompt != nil || context.server.files.isEmpty || context.server.files.allSatisfy { ![.available, .leased].contains($0.state) }) }
    }

    private func makeContext(count: Int, failApprovals: Bool = false) throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = IPhoneReceiveApprovalStore(fileURL: directory.appendingPathComponent("approvals.json"))
        let server = ArrivalTestServer(files: (1..<(count + 1)).map { file(index: $0) }, store: store)
        let model = IPhoneIncomingFilesViewModel(
            loadPendingFiles: { try await server.snapshot() },
            approveFiles: { receiver, ids, destination in
                if failApprovals { throw CocoaError(.fileWriteNoPermission) }
                guard receiver == server.receiverID else { throw URLError(.userAuthenticationRequired) }
                try store.approve(ids, receiverID: receiver, destination: destination)
            },
            sleep: { try await Task.sleep(for: .seconds(60)) }
        )
        addTeardownBlock { @MainActor in model.setActive(false) }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Context(model: model, server: server, store: store)
    }

    private func file(index: Int, state: IPhoneDeliveryState = .available) -> IPhoneDelivery {
        IPhoneDelivery(deliveryID: UUID(), fileName: "시험-\(index).zip", contentType: "application/zip", size: Int64(index * 1_000), sha256: String(repeating: "a", count: 64), state: state, createdAt: Date(timeIntervalSince1970: Double(index)), expiresAt: Date.distantFuture, deliveredAt: nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Arrival simulation did not reach the expected state")
    }

    private struct Context {
        let model: IPhoneIncomingFilesViewModel
        let server: ArrivalTestServer
        let store: IPhoneReceiveApprovalStore
    }
}

private final class ArrivalTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var identity = UUID()
    private var values: [IPhoneDelivery]
    private var calls = 0
    private var completed = 0
    private var failure: Error?
    private var queryGate: ArrivalQueryGate?
    private let store: IPhoneReceiveApprovalStore

    init(files: [IPhoneDelivery], store: IPhoneReceiveApprovalStore) { values = files; self.store = store }
    var receiverID: UUID { get { lock.withLock { identity } } set { lock.withLock { identity = newValue } } }
    var files: [IPhoneDelivery] { lock.withLock { values } }
    var callCount: Int { lock.withLock { calls } }
    var completedCalls: Int { lock.withLock { completed } }
    var error: Error? { get { lock.withLock { failure } } set { lock.withLock { failure = newValue } } }
    var gate: ArrivalQueryGate? { get { lock.withLock { queryGate } } set { lock.withLock { queryGate = newValue } } }
    func append(_ file: IPhoneDelivery) { lock.withLock { values.append(file) } }
    func replace(_ files: [IPhoneDelivery]) { lock.withLock { values = files } }

    func snapshot() async throws -> IPhoneIncomingSnapshot {
        let captured = lock.withLock { () -> (UUID, [IPhoneDelivery], Error?, ArrivalQueryGate?) in
            calls += 1
            return (identity, values, failure, queryGate)
        }
        if let gate = captured.3 { await gate.wait() }
        defer { lock.withLock { completed += 1 } }
        if let error = captured.2 { throw error }
        let approved = try store.destinations(receiverID: captured.0)
        return IPhoneIncomingSnapshot(receiverID: captured.0, files: captured.1.filter { approved[$0.deliveryID] == nil })
    }
}

private actor ArrivalQueryGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
