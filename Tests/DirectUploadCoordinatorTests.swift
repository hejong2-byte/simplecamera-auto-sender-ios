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

        XCTAssertEqual(try await ledger.record(id: "simple-1")?.state, .queued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await transport.succeed(statusCode: 201)
        try await upload.value

        XCTAssertEqual(try await ledger.record(id: "simple-1")?.state, .uploaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
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

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
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
    }
}
