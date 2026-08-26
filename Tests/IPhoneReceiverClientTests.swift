import XCTest
@testable import SimpleCameraAutoSender

final class IPhoneReceiverClientTests: XCTestCase {
    func testReceiverKeychainAccountsAreSeparatedFromUploadAuthorization() {
        XCTAssertNotEqual(
            AppConfiguration.receiveSecretKeychainAccount,
            AppConfiguration.keychainAccount
        )
        XCTAssertNotEqual(
            AppConfiguration.receiverIdentityKeychainAccount,
            AppConfiguration.receiveSecretKeychainAccount
        )
    }

    func testRequestFactoryBuildsRegistrationListRangeLeaseAndAckContracts() throws {
        let receiverID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let deliveryID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let factory = IPhoneReceiverRequestFactory(baseURL: AppConfiguration.relayAPIBaseURL)

        let registration = try factory.registration(
            uploadCredential: "Bearer upload",
            deviceName: "희종의 iPhone"
        )
        let list = try factory.list(
            receiverID: receiverID,
            receiveSecret: "receive-secret"
        )
        let range = try factory.range(
            receiverID: receiverID,
            deliveryID: deliveryID,
            receiveSecret: "receive-secret",
            start: 8,
            end: 15
        )
        let lease = try factory.lease(
            receiverID: receiverID,
            deliveryID: deliveryID,
            receiveSecret: "receive-secret"
        )
        let ack = try factory.ack(
            receiverID: receiverID,
            deliveryID: deliveryID,
            receiveSecret: "receive-secret",
            sha256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(registration.httpMethod, "POST")
        XCTAssertTrue(registration.url?.path.hasSuffix("/iphone-receivers/register") == true)
        XCTAssertEqual(list.httpMethod, "GET")
        XCTAssertEqual(range.value(forHTTPHeaderField: "Range"), "bytes=8-15")
        XCTAssertEqual(lease.httpMethod, "POST")
        XCTAssertEqual(ack.httpMethod, "POST")
        XCTAssertEqual(
            list.value(forHTTPHeaderField: "Authorization"),
            "Bearer receive-secret"
        )
    }
}

