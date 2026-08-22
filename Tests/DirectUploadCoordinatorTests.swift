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

    func testFingerprintIsStableAndUsesUUIDVersionFourShape() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("media.mov")
        try Data("same media".utf8).write(to: fileURL)

        let first = try UploadFileFingerprinter.fingerprint(fileURL: fileURL)
        let second = try UploadFileFingerprinter.fingerprint(fileURL: fileURL)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.size, 10)
        XCTAssertNotNil(UUID(uuidString: first.remoteID))
        XCTAssertEqual(first.remoteID[first.remoteID.index(first.remoteID.startIndex, offsetBy: 14)], "4")
    }

    func testLargeManualFileUsesMultipartPartsAndCompletes() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        try await ledger.recordDiscovery(id: "video-1", createdAt: .now)
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test")
        let transport = MultipartHTTPFileUploader()
        let coordinator = BackgroundUploadCoordinator(
            ledger: ledger,
            credentialStore: credentials,
            transport: transport,
            manualUploadPolicy: ManualMediaUploadPolicy(
                maxBytes: 100,
                singleRequestMaxBytes: 4,
                multipartPartBytes: 4
            )
        )
        let fileURL = directory.appendingPathComponent("video.mov")
        try Data("0123456789".utf8).write(to: fileURL)

        try await coordinator.upload(
            assetID: "video-1",
            fileURL: fileURL,
            metadata: ManualMediaUploadMetadata(
                fileName: "video.mov",
                contentType: "video/quicktime",
                capturedAt: nil
            )
        )

        let calls = await transport.calls
        let state = try await ledger.record(id: "video-1")?.state
        XCTAssertEqual(calls.map(\.method), ["POST", "PUT", "PUT", "PUT", "POST"])
        XCTAssertEqual(calls.filter { $0.path.contains("/parts/") }.map(\.size), [4, 4, 2])
        XCTAssertEqual(state, .uploaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testManualFileOverConfiguredLimitStopsBeforeNetwork() async throws {
        let directory = temporaryDirectory()
        let ledger = try UploadLedger(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        try await ledger.recordDiscovery(id: "too-large", createdAt: .now)
        let credentials = InMemoryCredentialStore()
        try credentials.save("Bearer test")
        let transport = MultipartHTTPFileUploader()
        let coordinator = BackgroundUploadCoordinator(
            ledger: ledger,
            credentialStore: credentials,
            transport: transport,
            manualUploadPolicy: ManualMediaUploadPolicy(
                maxBytes: 5,
                singleRequestMaxBytes: 4,
                multipartPartBytes: 4
            )
        )
        let fileURL = directory.appendingPathComponent("large.mov")
        try Data("123456".utf8).write(to: fileURL)

        do {
            try await coordinator.upload(
                assetID: "too-large",
                fileURL: fileURL,
                metadata: ManualMediaUploadMetadata(
                    fileName: "large.mov",
                    contentType: "video/quicktime",
                    capturedAt: nil
                )
            )
            XCTFail("크기 초과 오류가 필요합니다.")
        } catch let error as ManualMediaUploadError {
            XCTAssertEqual(error, .fileTooLarge(maxBytes: 5))
        }
        let callCount = await transport.calls.count
        XCTAssertEqual(callCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor MultipartHTTPFileUploader: HTTPFileUploading {
    struct Call: Sendable {
        let method: String
        let path: String
        let size: Int
    }

    private(set) var calls: [Call] = []

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        let size = (try? Data(contentsOf: fileURL).count) ?? 0
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        calls.append(Call(method: method, path: path, size: size))

        let data: Data
        let status: Int
        if path == "/api/media/multipart" {
            data = Data(#"{"uploadId":"upload-1"}"#.utf8)
            status = 201
        } else if path.contains("/parts/") {
            let number = Int(path.split(separator: "/").last ?? "0") ?? 0
            data = try JSONSerialization.data(withJSONObject: [
                "partNumber": number,
                "etag": "etag-\(number)",
            ])
            status = 200
        } else if path.hasSuffix("/complete") {
            data = Data(#"{"ok":true}"#.utf8)
            status = 201
        } else {
            data = Data()
            status = 204
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
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
