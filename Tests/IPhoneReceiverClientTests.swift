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

    func testRegistrationAndDeliveryJSONDecodeServerContract() throws {
        let decoder = IPhoneReceiverJSON.decoder
        let registration = try decoder.decode(
            IPhoneReceiverRegistration.self,
            from: Data(
                #"{"receiverId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","code":"123456","receiveSecret":"secret","deviceName":"희종의 iPhone"}"#.utf8
            )
        )
        let deliveries = try decoder.decode(
            [IPhoneDelivery].self,
            from: Data(
                #"[{"deliveryId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"업무.zip","contentType":"application/zip","size":40,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"available","createdAt":"2026-08-26T00:00:00Z","expiresAt":"2026-09-02T00:00:00Z","deliveredAt":null}]"#.utf8
            )
        )

        XCTAssertEqual(registration.receiverID.uuidString.lowercased(), "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertEqual(registration.code, "123456")
        XCTAssertEqual(deliveries.first?.fileName, "업무.zip")
        XCTAssertEqual(deliveries.first?.size, 40)
        XCTAssertEqual(deliveries.first?.state, .available)
    }

    func testRegistrationStoreKeepsIdentityAndSecretSeparate() throws {
        let identityCredential = InMemoryCredentialStore()
        let secretCredential = InMemoryCredentialStore()
        let store = IPhoneReceiverRegistrationStore(
            identityStore: identityCredential,
            secretStore: secretCredential
        )
        let registration = IPhoneReceiverRegistration(
            receiverID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            code: "123456",
            receiveSecret: "receive-secret",
            deviceName: "희종의 iPhone"
        )

        try store.save(registration)

        XCTAssertEqual(try store.load()?.identity.receiverID, registration.receiverID)
        XCTAssertEqual(try store.load()?.secret, "receive-secret")
        XCTAssertFalse((try identityCredential.load() ?? "").contains("receive-secret"))
        XCTAssertEqual(try secretCredential.load(), "receive-secret")
    }
}
