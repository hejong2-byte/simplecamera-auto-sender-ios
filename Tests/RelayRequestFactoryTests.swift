import XCTest
@testable import SimpleCameraAutoSender

final class RelayRequestFactoryTests: XCTestCase {
    func testGeneralFilesUseDedicatedRoutesAndKeepOriginalMetadata() throws {
        let factory = RelayRequestFactory()
        let fingerprint = UploadFileFingerprint(sha256: String(repeating: "a", count: 64), size: 20,
            remoteID: "123e4567-e89b-42d3-a456-426614174000")
        let metadata = ManualMediaUploadMetadata(fileName: "카카오톡 문서.hwpx", contentType: "application/zip", capturedAt: nil)
        let single = try factory.makeManualMediaRequest(credential: "Bearer test", fingerprint: fingerprint, metadata: metadata, fileTransfer: true)
        let start = try factory.makeMultipartStartRequest(credential: "Bearer test", fingerprint: fingerprint, metadata: metadata, fileTransfer: true)
        let part = try factory.makeMultipartPartRequest(credential: "Bearer test", remoteID: fingerprint.remoteID, uploadID: "opaque/+id", partNumber: 2, partSize: 10, fileTransfer: true)
        let complete = try factory.makeMultipartCompleteRequest(credential: "Bearer test", remoteID: fingerprint.remoteID, uploadID: "opaque/+id", fileTransfer: true)
        let abort = try factory.makeMultipartAbortRequest(credential: "Bearer test", remoteID: fingerprint.remoteID, uploadID: "opaque/+id", fileTransfer: true)

        XCTAssertEqual(single.url?.path, "/api/files/\(fingerprint.remoteID)")
        XCTAssertEqual(start.url?.path, "/api/files/multipart")
        XCTAssertEqual(part.url?.path, "/api/files/multipart/\(fingerprint.remoteID)/parts/2")
        XCTAssertEqual(complete.url?.path, "/api/files/multipart/\(fingerprint.remoteID)/complete")
        XCTAssertEqual(abort.url?.path, "/api/files/multipart/\(fingerprint.remoteID)")
        XCTAssertEqual(single.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Media-Type"), "application/zip")
        XCTAssertEqual(single.value(forHTTPHeaderField: "X-File-Name")?.removingPercentEncoding, metadata.fileName)
        XCTAssertEqual(single.value(forHTTPHeaderField: "X-Content-SHA256"), fingerprint.sha256)
        XCTAssertNil(single.value(forHTTPHeaderField: "X-Captured-At"))
        let media = try factory.makeManualMediaRequest(credential: "Bearer test", fingerprint: fingerprint, metadata: metadata)
        XCTAssertEqual(media.url?.path, "/api/photos/\(fingerprint.remoteID)")
    }

    func testRequestMatchesRelayContract() throws {
        let request = try RelayRequestFactory().makeUploadRequest(credential: "test-secret")
        XCTAssertEqual(request.url, AppConfiguration.relayEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-secret")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/octet-stream"
        )
        XCTAssertNil(request.httpBody)
    }

    func testEmptyCredentialIsRejected() {
        XCTAssertThrowsError(
            try RelayRequestFactory().makeUploadRequest(credential: "  ")
        )
    }

    func testManualRequestCarriesOriginalMetadataAndIntegrityHeaders() throws {
        let fingerprint = UploadFileFingerprint(
            sha256: String(repeating: "a", count: 64),
            size: 400_000_000,
            remoteID: "123e4567-e89b-42d3-a456-426614174000"
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let request = try RelayRequestFactory().makeManualMediaRequest(
            credential: "Bearer test",
            fingerprint: fingerprint,
            metadata: ManualMediaUploadMetadata(
                fileName: "업무 동영상.MOV",
                contentType: "video/quicktime",
                capturedAt: capturedAt
            )
        )

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url?.absoluteString.hasSuffix(fingerprint.remoteID) == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/quicktime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-SHA256"), fingerprint.sha256)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-File-Size"), "400000000")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-File-Name"),
            "%EC%97%85%EB%AC%B4%20%EB%8F%99%EC%98%81%EC%83%81.MOV"
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Captured-At"))
    }

    func testMultipartPartRequestKeepsOpaqueUploadIDInQuery() throws {
        let request = try RelayRequestFactory().makeMultipartPartRequest(
            credential: "Bearer test",
            remoteID: "123e4567-e89b-42d3-a456-426614174000",
            uploadID: "opaque/upload+id",
            partNumber: 3,
            partSize: 32 * 1024 * 1024
        )
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url?.path.hasSuffix("/parts/3") == true)
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "uploadId" })?.value,
            "opaque/upload+id"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Part-Size"), "33554432")
    }

    func testDecodesOnlyStableRelayErrorCode() {
        let body = Data(#"{"error":"size_mismatch","details":"do not display"}"#.utf8)

        XCTAssertEqual(RelayRequestFactory().decodeErrorCode(from: body), "size_mismatch")
        XCTAssertNil(RelayRequestFactory().decodeErrorCode(from: Data("not-json".utf8)))
    }
}
