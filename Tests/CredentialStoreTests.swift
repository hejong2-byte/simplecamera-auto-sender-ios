import XCTest
@testable import SimpleCameraAutoSender

final class CredentialStoreTests: XCTestCase {
    func testEndpointIsExistingRelayUploadContract() {
        XCTAssertEqual(
            AppConfiguration.relayEndpoint.absoluteString,
            "https://simplecamera-work-photo-relay.simplecamera-work-photo-relay.workers.dev/api/shortcut/photos"
        )
    }

    func testInMemoryStoreRoundTripAndClear() throws {
        let store = InMemoryCredentialStore()
        try store.save("secret-value")
        XCTAssertEqual(try store.load(), "secret-value")
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testEmptyCredentialIsRejected() {
        let store = InMemoryCredentialStore()
        XCTAssertThrowsError(try store.save("   \n"))
    }
}
