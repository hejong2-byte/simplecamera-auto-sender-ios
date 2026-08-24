import Foundation
import XCTest
@testable import SimpleCameraAutoSender

final class DirectUploadCoordinatorTests: XCTestCase {
    func testUploadReturnsOnlyAfterHTTP2xxAndThenMarksUploaded() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        try await ledger.recordDiscovery(
            id: "simple-1",
            createdAt: .now
        )
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let transport = ControlledHTTPFileUploader()
        let coordinator = BackgroundUploadCoordinator(
            ledger: ledger,
            credentialStore: credentials,
            transport: transport
        )
        let fileURL = directory.appendingPathComponent("simple.jpg")
        try Data("photo".utf8).write(to: fileURL)

        let upload = Task {
            try await coordinator.upload(
                assetID: "simple-1",
                fileURL: fileURL
            )
        }
        await transport.waitUntilStarted()

        let queuedState = try await ledger.record(id: "simple-1")?.state
        XCTAssertEqual(queuedState, .queued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await transport.succeed(statusCode: 201)
        try await upload.value

        let uploadedState = try await ledger.record(id: "simple-1")?.state
        XCTAssertEqual(uploadedState, .uploaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUploadForwardsActualBodyByteProgressBeforeHTTPCompletion() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        try await ledger.recordDiscovery(
            id: "simple-progress",
            createdAt: .now
        )
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-secret")
        let transport = ControlledHTTPFileUploader()
        let coordinator = BackgroundUploadCoordinator(
            ledger: ledger,
            credentialStore: credentials,
            transport: transport
        )
        let fileURL = directory.appendingPathComponent("simple.jpg")
        try Data(repeating: 1, count: 10).write(to: fileURL)
        let received = UploadProgressRecorder()

        let upload = Task {
            try await coordinator.upload(
                assetID: "simple-progress",
                fileURL: fileURL
            ) { sent, total in
                received.record(sent: sent, total: total)
            }
        }
        await transport.waitUntilStarted()

        await transport.report(sent: 3, total: 10)
        for _ in 0..<200 where received.last?.sent != 3 {
            await Task.yield()
        }

        XCTAssertEqual(received.last?.sent, 3)
        XCTAssertEqual(received.last?.total, 10)
        await transport.succeed(statusCode: 201)
        try await upload.value
    }

    func testFingerprintIsStableAndUsesUUIDVersionFourShape() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("media.mov")
        try Data("same media".utf8).write(to: fileURL)

        let first = try UploadFileFingerprinter.fingerprint(fileURL: fileURL)
        let second = try UploadFileFingerprinter.fingerprint(fileURL: fileURL)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.size, 10)
        XCTAssertNotNil(UUID(uuidString: first.remoteID))
        XCTAssertEqual(first.remoteID[first.remoteID.index(first.remoteID.startIndex, offsetBy: 14)], "4")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor ControlledHTTPFileUploader: HTTPFileUploading {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (Data, URLResponse) {
        progressHandler = onProgress
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func succeed(statusCode: Int) {
        let response = HTTPURLResponse(
            url: AppConfiguration.relayEndpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        continuation?.resume(returning: (Data(), response))
        continuation = nil
        progressHandler = nil
    }

    func report(sent: Int64, total: Int64) {
        progressHandler?(sent, total)
    }
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (sent: Int64, total: Int64)?

    var last: (sent: Int64, total: Int64)? {
        lock.withLock { value }
    }

    func record(sent: Int64, total: Int64) {
        lock.withLock { value = (sent, total) }
    }
}
