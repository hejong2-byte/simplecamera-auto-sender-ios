import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class BackgroundIPhoneReceiveSessionTests: XCTestCase {
    func testSystemCompletionWaitsForDeliveredSuccessCallbackToFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = BackgroundSessionCompletionRegistry()
        let receiver = try BackgroundIPhoneReceiveSession(stagingDirectory: directory, completionRegistry: registry)
        let entered = expectation(description: "Success callback entered")
        let completed = expectation(description: "System completion")
        let sink = BlockingReceiveFailureSink(entered: entered)
        let state = ReceiveCompletionFlag()
        receiver.bind(sink: sink)
        registry.store(identifier: AppConfiguration.receiverBackgroundSessionIdentifier) {
            state.markCompleted()
            completed.fulfill()
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let deliveryID = UUID()
        let task = SuccessfulReceiveDownloadTask()
        task.taskDescription = try IPhoneReceiveTaskDescriptor(deliveryID: deliveryID).encodedTaskDescription()
        let incoming = directory.appendingPathComponent("fixture.tmp")
        let payload = Data("delivered".utf8)
        try payload.write(to: incoming)
        receiver.urlSession(session, downloadTask: task, didFinishDownloadingTo: incoming)
        await fulfillment(of: [entered], timeout: 2)
        let staging = directory.appendingPathComponent(deliveryID.uuidString.lowercased() + ".download")
        XCTAssertEqual(try Data(contentsOf: staging), payload)

        receiver.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(state.completed, "Moved staging alone is not durable completion of its delivered callback")
        await sink.release()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(state.completed)
    }

    func testSystemCompletionWaitsForDeliveredFailureCallbackToFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = BackgroundSessionCompletionRegistry()
        let receiver = try BackgroundIPhoneReceiveSession(stagingDirectory: directory, completionRegistry: registry)
        let entered = expectation(description: "Failure callback entered")
        let completed = expectation(description: "System completion")
        let sink = BlockingReceiveFailureSink(entered: entered)
        let state = ReceiveCompletionFlag()
        receiver.bind(sink: sink)
        registry.store(identifier: AppConfiguration.receiverBackgroundSessionIdentifier) {
            state.markCompleted()
            completed.fulfill()
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/download")!)
        task.taskDescription = try IPhoneReceiveTaskDescriptor(deliveryID: UUID()).encodedTaskDescription()
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
        await fulfillment(of: [entered], timeout: 2)

        receiver.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        // A main-queue barrier observes the system completion dispatch while the sink is blocked.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(state.completed, "System completion must wait for delivered callback durability")
        await sink.release()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(state.completed)
    }

    func testDescriptorRoundTripKeepsDeliveryIdentity() throws {
        let descriptor = IPhoneReceiveTaskDescriptor(deliveryID: UUID())

        XCTAssertEqual(
            try IPhoneReceiveTaskDescriptor(
                taskDescription: descriptor.encodedTaskDescription()
            ),
            descriptor
        )
    }

    func testCompletionRegistryFinishesOnlyMatchingSession() {
        let registry = BackgroundSessionCompletionRegistry()
        var manual = 0
        var receive = 0
        registry.store(identifier: "manual") { manual += 1 }
        registry.store(identifier: "receive") { receive += 1 }

        registry.finish(identifier: "receive")

        XCTAssertEqual(manual, 0)
        XCTAssertEqual(receive, 1)
        registry.finish(identifier: "receive")
        XCTAssertEqual(receive, 1)
        registry.finish(identifier: "manual")
        XCTAssertEqual(manual, 1)
    }

    func testReceiveBackgroundIdentifierIsDistinctFromManualUpload() {
        XCTAssertNotEqual(
            AppConfiguration.receiverBackgroundSessionIdentifier,
            AppConfiguration.manualBackgroundSessionIdentifier
        )
    }
}

private final class ReceiveCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var completed: Bool { lock.withLock { value } }
    func markCompleted() { lock.withLock { value = true } }
}

private actor BlockingReceiveFailureSink: IPhoneReceiveDownloadSink {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }
    func downloadProgress(deliveryID: UUID, received: Int64, expected: Int64) async {}
    func downloadFinished(deliveryID: UUID, stagingURL: URL) async {
        await waitForRelease()
    }
    func downloadFailed(deliveryID: UUID, error: Error) async {
        await waitForRelease()
    }
    private func waitForRelease() async {
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

private final class SuccessfulReceiveDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    override var response: URLResponse? {
        HTTPURLResponse(url: URL(string: "https://example.invalid/download")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)
    }
}
