import XCTest
@testable import SimpleCameraAutoSender

final class RelayRequestFactoryTests: XCTestCase {
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
}
